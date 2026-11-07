-- Production footprints are not transit space, including their empty interior.
local M={}
local work=require('generation_work')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
-- Perimeter collectors are added after the production templates. They remain
-- routable logistics outside the protected production footprint.
function M.freeze(entities,blocks)
 for _,b in ipairs(blocks) do b.route_entity_ids={}
  for i=b.entity_first,b.entity_last do b.route_entity_ids[entities[i].entity_number]=true end
 end
end
function M.capture(entities,blocks)
 for _,b in ipairs(blocks) do if b.entity_first and b.entity_last then
  local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
  local ml,mt,mr,mb=math.huge,math.huge,-math.huge,-math.huge
  for i=b.entity_first,b.entity_last do local e=entities[i];if not b.route_entity_ids or b.route_entity_ids[e.entity_number] then local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
   if (e.direction or 0)%8==4 then w,h=h,w end
   if e.recipe or p.type=='furnace' then ml=math.min(ml,math.floor(e.position.x-w/2+.001));mt=math.min(mt,math.floor(e.position.y-h/2+.001));mr=math.max(mr,math.ceil(e.position.x+w/2-.001)-1);mb=math.max(mb,math.ceil(e.position.y+h/2-.001)-1) end
   left=math.min(left,math.floor(e.position.x-w/2+.001));top=math.min(top,math.floor(e.position.y-h/2+.001))
   right=math.max(right,math.ceil(e.position.x+w/2-.001)-1);bottom=math.max(bottom,math.ceil(e.position.y+h/2-.001)-1)
  end end
  if ml<math.huge then b.route_machine_bounds={left=ml,top=mt,right=mr,bottom=mb} end
  if left<math.huge then b.route_owner=b.routing_group; b.route_bounds={left=left,top=top,right=right,bottom=bottom} end
 end end
end
function M.build(blocks)
 -- Replayed callers receive fresh metadata, but the protected geometry is
 -- unchanged within this routing stage. Restore owners even on a cache hit.
 for i,b in ipairs(blocks) do if b.route_bounds then b.route_owner=b.routing_group or i end end
 return work.cached('routing-boundaries',function()
 local groups,cells,access,machines,owners,cluster_boxes,cluster_cells,owner_clusters={},{},{},{},{},{},{},{}
 for i,b in ipairs(blocks) do local r=b.route_bounds
  if r then local owner=b.route_owner;local g=groups[owner]
   local cluster=b.routing_cluster and ('c'..b.routing_cluster) or ('b'..owner);owner_clusters[owner]=cluster
   local box=cluster_boxes[cluster]
   if not box then cluster_boxes[cluster]={left=r.left,top=r.top,right=r.right,bottom=r.bottom}
   else box.left=math.min(box.left,r.left);box.top=math.min(box.top,r.top);box.right=math.max(box.right,r.right);box.bottom=math.max(box.bottom,r.bottom) end
   if not g then g={left=r.left,top=r.top,right=r.right,bottom=r.bottom};groups[owner]=g
   else g.left=math.min(g.left,r.left);g.top=math.min(g.top,r.top);g.right=math.max(g.right,r.right);g.bottom=math.max(g.bottom,r.bottom) end
  end
 end
 for owner,g in pairs(groups) do for x=g.left,g.right do for y=g.top,g.bottom do local k=key(x,y)
  cells[k]=cells[k] and cells[k]~=owner and 0 or owner
 end end end
 for cluster,g in pairs(cluster_boxes) do for x=g.left,g.right do for y=g.top,g.bottom do cluster_cells[key(x,y)]=cluster end end end
 for i,b in ipairs(blocks) do local r=b.route_machine_bounds;if r then for x=r.left,r.right do for y=r.top,r.bottom do machines[key(x,y)]=true end end end end
 local aprons={}
 local function port(p,owner,sign)
  if not p then return end;owners[key(p.x,p.y)]=owner;local g=groups[owner];if not g then return end
  local v=vectors[p.direction or 8];local allowed=access[key(p.x,p.y)] or {};access[key(p.x,p.y)]=allowed
  local x,y=p.x,p.y
  for step=0,math.max(g.right-g.left,g.bottom-g.top)+2 do
   if cells[key(x,y)]==owner then allowed[key(x,y)]=true
   else
    -- Leave a surface landing outside the production footprint. A crossing
    -- may end there without tunnelling through the production header itself.
    if cells[key(x,y)]==nil then
      allowed[key(x,y)]=true;aprons[#aprons+1]={owner=key(p.x,p.y),x=x,y=y,dx=v[2]*sign,dy=-v[1]*sign}
    end
    break
   end
   x,y=x+v[1]*sign,y+v[2]*sign
  end
 end
 for i,b in ipairs(blocks) do local owner=b.routing_group or i
  port(b.product_out,owner,1)
  for _,p in ipairs(b.output_ports or {}) do port(p,owner,1) end
  for _,p in pairs(b.product_outs or {}) do port(p,owner,1) end
  for _,p in ipairs(b.inputs or {}) do if not p.array_local then port(p,owner,-1) end end
 end
 -- One lateral surface landing lets a necessary crossing end OUTSIDE the
 -- block and turn into the inlet. Never overlap another declared approach.
 local claimed={}
 for owner,points in pairs(access) do for k in pairs(points) do claimed[k]=claimed[k] or {};claimed[k][owner]=true end end
 for _,p in ipairs(aprons) do for _,sign in ipairs({1,-1}) do
  local k=key(p.x+p.dx*sign,p.y+p.dy*sign);local free=cells[k]==nil
  for owner in pairs(claimed[k] or {}) do if owner~=p.owner then free=false end end
  if free then access[p.owner][k]=true;claimed[k]=claimed[k] or {};claimed[k][p.owner]=true;break end
 end end
 return cells,access,machines,owners,cluster_cells,owner_clusters,cluster_boxes
 end,true)
end
return M
