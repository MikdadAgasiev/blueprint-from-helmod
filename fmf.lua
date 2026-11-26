-- Promote straight, unbranched ordinary-pipe cuts into directed FMF bridges.
-- Preserve all machine/interface ports and reject contacts outside the two endpoints.
local M={}
local work=require('generation_work')
local equipment=require('equipment')
local pair=require('pipe_pair')
local graph=require('fluid_graph')
local topology=require('fmf_topology')
local orientation=require('orientation')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local dirs={0,4,8,12}
local function key(x,y)return x..','..y end
local function encode(values)
 local out={};for _,v in ipairs(values) do out[#out+1]=type(v)=='number' and string.format('%.8g',v) or v end;return table.concat(out,'/')
end
local function compatible(a,b)
 for _,x in ipairs(a or {}) do for _,y in ipairs(b or {}) do if x==y then return true end end end
 return false
end
local function openings(e)
 local result={};local p=prototypes.entity[e.name];local rotation=e.direction or 0
 for _,box in pairs(p.fluidbox_prototypes or {}) do for _,c in ipairs(box.pipe_connections) do
  local pos=c.positions and c.positions[rotation/4+1];local d=c.direction and (c.direction+rotation)%16
  if pos and vectors[d] and c.connection_type=='normal' then
   result[#result+1]={x=math.floor(e.position.x+pos.x),y=math.floor(e.position.y+pos.y),dir=d,categories=c.connection_category}
  end
 end end
 return result
end
local function signature(name)
 local p=prototypes.entity[name];if not p or #p.fluidbox_prototypes~=1 then return end
 local box=p.fluidbox_prototypes[1];if box.filter then return end
 local values={}
 for _,c in ipairs(box.pipe_connections) do
  if c.connection_type~='normal' or #c.connection_category~=1 then return end
  local pos=c.positions[1];values[#values+1]=encode({c.direction,pos.x,pos.y,c.flow_direction or 'input-output',c.connection_category[1]})
 end
 table.sort(values);return table.concat(values,';')
end
local function expected(values)
 local out={};for _,v in ipairs(values) do out[#out+1]=encode(v) end;table.sort(out);return table.concat(out,';')
end
local default_ports={{4,.5,-.5},{4,.5,.5},{8,.5,.5},{8,-.5,.5},{12,-.5,-.5},{12,-.5,.5}}
local exhaust_ports={{0,.5,-.5},{0,-.5,-.5},{4,.5,-.5},{4,.5,.5},{12,-.5,-.5},{12,-.5,.5}}
function M.catalog(force,pipe,items)
 local unlocked={};for _,name in pairs(items or equipment.items(force)) do unlocked[name]=true end
 local result={available=false,pipe=pipe or 'pipe'}
 local intake={{0,0,-.5,'output','ducts'}};for _,c in ipairs(default_ports) do intake[#intake+1]={c[1],c[2],c[3],'input','default'} end
 local exhaust={{8,0,.5,'input','ducts'}};for _,c in ipairs(exhaust_ports) do exhaust[#exhaust+1]={c[1],c[2],c[3],'output','default'} end
 local specs={
  ['duct-intake']={2,2,'pump',expected(intake)},['duct-exhaust']={2,2,'pump',expected(exhaust)},
  duct={2,2,'storage-tank',expected({{0,0,-.5,'input-output','ducts'},{8,0,.5,'input-output','ducts'}})},
  ['duct-small']={2,1,'storage-tank',expected({{0,0,-.25,'input-output','ducts'},{8,0,.25,'input-output','ducts'}})},
  ['duct-long']={2,4,'storage-tank',expected({{0,0,-1.5,'input-output','ducts'},{8,0,1.5,'input-output','ducts'}})},
 }
 for _,name in ipairs({'duct-intake','duct-exhaust','duct','duct-small','duct-long'}) do
  local p=prototypes.entity[name];local spec=specs[name]
  local valid=p and p.type==spec[3] and p.tile_width==spec[1] and p.tile_height==spec[2] and signature(name)==spec[4]
  if name=='duct-long' then result.long=valid and unlocked[name]==true
  elseif name=='duct' then result.standard=valid and unlocked[name]==true
  elseif not valid or not unlocked[name] then result.reason='equipment';return result end
  -- With auto-join enabled FMF intentionally has no construction items for
  -- standard/long ducts. Emit researched short pieces; let normal build events join them.
  if not valid then result.reason='geometry';return result end
 end
 local p=prototypes.entity[result.pipe]
 if not p or p.type~='pipe' or p.tile_width~=1 or p.tile_height~=1 or signature(result.pipe)~=expected({{0,0,0,'input-output','default'},{4,0,0,'input-output','default'},{8,0,0,'input-output','default'},{12,0,0,'input-output','default'}}) then result.reason='pipe';return result end
 result.underground,result.distance=pair.resolve(result.pipe)
 if result.underground then
  local underground=prototypes.entity[result.underground];local boxes=underground.fluidbox_prototypes
  local valid=unlocked[result.underground] and #boxes==1 and not boxes[1].filter and #boxes[1].pipe_connections==2
  for _,c in ipairs(boxes[1].pipe_connections) do
   if (c.connection_type=='normal' and c.direction~=0) or (c.connection_type=='underground' and c.direction~=8) or (c.connection_type~='normal' and c.connection_type~='underground') or c.flow_direction and c.flow_direction~='input-output' then valid=false end
   for _,pos in ipairs(c.positions or {}) do if pos.x~=0 or pos.y~=0 then valid=false end end
  end
  if not valid then result.reason='underground';return result end
 end
 result.nominal=math.min(prototypes.entity['duct-intake'].get_pumping_speed('normal') or 0,prototypes.entity['duct-exhaust'].get_pumping_speed('normal') or 0)*60
 -- Nominal pump speed is an upper bound, not sustained throughput. Keep a
 -- twofold nominal margin in this initial topology; physical tests cover this limit.
 -- A bridge currently uses one default-network port per boundary. The
 -- engine caps a flow operation at 100/tick; keep headroom at that port too.
 result.limit=math.min(result.nominal/2,3000)
 local ordinary=prototypes.entity.pump
 result.pump_capacity=unlocked.pump and ordinary and ordinary.tile_width==1 and ordinary.tile_height==2 and (ordinary.get_pumping_speed('normal')or 0)*60 or 0
 result.ordinary_extent=prototypes.utility_constants and prototypes.utility_constants.default_pipeline_extent or 320
 result.junctions={}
 for name,ds in pairs({['duct-curve']={0,12},['duct-t-junction']={0,4,12},['duct-cross']={0,4,8,12}})do
  local p=prototypes.entity[name];local spec={}
  for _,d in ipairs(ds)do local v=vectors[d];spec[#spec+1]={d,v[1]*.5,v[2]*.5,'input-output','ducts'}end
  if unlocked[name]and p and p.type=='storage-tank'and p.tile_width==2 and p.tile_height==2 and signature(name)==expected(spec)then result.junctions[name]=ds end
 end
 local valve=prototypes.entity['non-return-duct']
 result.priority=unlocked['non-return-duct']==true and valve and valve.type=='pump'
  and valve.tile_width==2 and valve.tile_height==2
  and signature('non-return-duct')==expected({{0,0,-.5,'output','ducts'},{8,0,.5,'input','ducts'}})
 if result.priority then result.priority_limit=math.min(result.limit,(valve.get_pumping_speed('normal') or 0)*30) end
 result.available=result.limit>0;return result
end
function M.export_gate(output,en,catalog)
 if not catalog or not catalog.priority or output.rate>(catalog.priority_limit or catalog.limit)+1e-8 then return end
 local turns=((output.direction-4)/4)%4
 local gate={
  {entity_number=en,name='duct-intake',position={x=2,y=1},direction=4},
  {entity_number=en+1,name='non-return-duct',position={x=4,y=1},direction=4},
  {entity_number=en+2,name='duct-exhaust',position={x=6,y=1},direction=4},
  {entity_number=en+3,name=catalog.pipe,position={x=7.5,y=.5},direction=0},
 }
 for _,entity in ipairs(gate) do
  entity.position.x=entity.position.x-.5;entity.position.y=entity.position.y-.5
  orientation.entity(entity,turns)
  entity.position.x=entity.position.x+output.x+.5
  entity.position.y=entity.position.y+output.y+.5
 end
 return gate,gate[2],7
end

function M.export_clear(gate,occupied,sensor)
 for _,entity in ipairs(gate) do
  for _,opening in ipairs(openings(entity)) do
   local v=vectors[opening.dir]
   local x,y=opening.x+v[1],opening.y+v[2]
   if occupied[key(x,y)] and (x~=sensor.x or y~=sensor.y) then return false end
  end
 end
 return true
end

local function step(a,s)
 if not s.phase then
  s.phase='base-check';s.check={};s.stats={bridges=0,pumps=0,ordinary=0,skipped={}};s.next_id=a.en
 end
 local function skip(reason)s.stats.skipped[reason]=(s.stats.skipped[reason] or 0)+1 end
 if s.phase=='base-check' then
  local done,issues=graph.step({entities=a.entities,ports=a.ports,independent=a.independent},s.check)
  if not done then return false end
  if #issues>0 then
   s.stats.skipped.invalid=1;for _,e in ipairs(a.entities) do if e.name==a.catalog.pipe or e.name==a.catalog.underground then s.stats.ordinary=s.stats.ordinary+1 end end
   return true,a.entities,a.en,s.stats
  end
  s.phase='index';s.index=1;s.nodes={};s.order={};s.occupied={};s.normal={};s.removed={};s.added={};s.protected={};s.roles={}
  s.access={};s.minx=math.huge;s.miny=math.huge;s.maxx=-math.huge;s.maxy=-math.huge
  for _,p in ipairs(a.ports) do
   local k=key(p.x,p.y);s.protected[k]=true;s.roles[k]=s.roles[k] or {};s.roles[k][#s.roles[k]+1]=p
   if p.external then local v=vectors[p.dir];for n=1,3 do s.access[key(p.x-v[1]*n,p.y-v[2]*n)]=true end end
  end
 end
 local function add_index(e,index)
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
  for xx=x,x+w-1 do for yy=y,y+h-1 do s.occupied[key(xx,yy)]=index end end
  for _,o in ipairs(openings(e)) do local k=key(o.x,o.y)..'/'..o.dir;o.index=index;s.normal[k]=s.normal[k] or {};s.normal[k][#s.normal[k]+1]=o end
 end
 if s.phase=='index' then
  while s.index<=#a.entities do
   if not work.consume(8) then return false end
   local i=s.index;s.index=i+1;local e=a.entities[i];add_index(e,i)
   if e.name==a.catalog.pipe or e.name==a.catalog.underground then
    local x,y=math.floor(e.position.x),math.floor(e.position.y);local k=key(x,y)
    local n={x=x,y=y,index=i,adj={},normal={}}
    for _,o in ipairs(openings(e)) do n.normal[o.dir]=true end
    if e.name==a.catalog.underground then n.ug=((e.direction or 0)+8)%16 end
    s.nodes[k]=n;s.order[#s.order+1]=k;s.minx=math.min(s.minx,x);s.maxx=math.max(s.maxx,x);s.miny=math.min(s.miny,y);s.maxy=math.max(s.maxy,y)
   end
  end
  table.sort(s.order);s.phase='edges';s.index=1
 end
 if s.phase=='edges' then
  while s.index<=#s.order do
   if not work.consume(8) then return false end
   local k=s.order[s.index];s.index=s.index+1;local n=s.nodes[k]
   for _,d in ipairs(dirs) do local v=vectors[d];local q=key(n.x+v[1],n.y+v[2]);local other=s.nodes[q]
    if n.normal[d] and other and other.normal[(d+8)%16] then n.adj[q]=true end
   end
   if n.ug then local v=vectors[n.ug]
    for distance=1,a.catalog.distance do local q=key(n.x+v[1]*distance,n.y+v[2]*distance);local other=s.nodes[q]
     if other and other.ug==(n.ug+8)%16 then n.adj[q]=true;break end
    end
   end
  end
  s.phase='candidates';s.index=1;s.candidates={}
 end
 local function straight(k,d)
  local n=s.nodes[k];if not n or n.ug or s.protected[k] then return false end
  local count=0;for q in pairs(n.adj) do count=count+1;local other=s.nodes[q];if d==4 and other.y~=n.y or d==8 and other.x~=n.x then return false end end
  return count==2
 end
 local function candidate(left,right,inside,d)
  if not left or not right or #inside==0 then return end
  local length=math.abs(left.x-right.x)+math.abs(left.y-right.y)
  if length>=9 and length<=66 then s.candidates[#s.candidates+1]={left=key(left.x,left.y),right=key(right.x,right.y),inside=inside,d=d,length=length} end
 end
 if s.phase=='candidates' then
  while s.index<=#s.order do
   if not work.consume(16) then return false end
   local k=s.order[s.index];s.index=s.index+1;local n=s.nodes[k]
   if n.ug==4 or n.ug==8 then
    local v=vectors[n.ug]
    for q in pairs(n.adj) do local other=s.nodes[q]
     if other.ug==(n.ug+8)%16 and not s.protected[k] and not s.protected[q] then
      candidate(s.nodes[key(n.x-v[1],n.y-v[2])],s.nodes[key(other.x+v[1],other.y+v[2])],{k,q},n.ug)
     end
    end
   elseif not n.ug then
    for _,d in ipairs({4,8}) do if not straight(k,d) or(d==4 and n.x%64==0)or(d==8 and n.y%64==0)then
     local v=vectors[d];local inside={};local cursor=n
     for length=1,66 do
      local q=key(cursor.x+v[1],cursor.y+v[2]);local next_node=s.nodes[q]
      if not next_node or not cursor.adj[q] then break end
      if length==66 or not straight(q,d) then candidate(n,next_node,inside,d);break end
      inside[#inside+1]=q;cursor=next_node
     end
    end end
   end
  end
  table.sort(s.candidates,function(x,y)if x.length~=y.length then return x.length>y.length end;local xn,yn=s.nodes[x.left],s.nodes[y.left];local xd=math.abs(xn.x+x.length/2*(x.d==4 and 1 or 0)-(s.minx+s.maxx)/2)+math.abs(xn.y+x.length/2*(x.d==8 and 1 or 0)-(s.miny+s.maxy)/2);local yd=math.abs(yn.x+y.length/2*(y.d==4 and 1 or 0)-(s.minx+s.maxx)/2)+math.abs(yn.y+y.length/2*(y.d==8 and 1 or 0)-(s.miny+s.maxy)/2);if xd~=yd then return xd<yd end;if x.left~=y.left then return x.left<y.left end;return x.d<y.d end)
  s.phase='choose';s.index=1
 end
 local function make_bridge(c,reverse,side)
  local start=s.nodes[reverse and c.right or c.left];local d=reverse and (c.d+8)%16 or c.d
  local v=vectors[d];local dx,dy=v[1],v[2];local tx,ty=-dy*side,dx*side
  -- A two-cell-wide corridor alongside the original pipe axis.
  local function center(along,width)
   return {x=start.x+.5+dx*(along+(width-1)/2)+tx*.5,y=start.y+.5+dy*(along+(width-1)/2)+ty*.5}
  end
  local result={{name='duct-intake',position=center(1,2),direction=d},{name='duct-exhaust',position=center(c.length-2,2),direction=d}}
  local x,remaining=3,c.length-5
  while remaining>0 do
   local width=a.catalog.long and remaining>=4 and 4 or a.catalog.standard and remaining>=2 and 2 or 1
   local name=width==4 and 'duct-long' or width==2 and 'duct' or 'duct-small'
   result[#result+1]={name=name,position=center(x,width),direction=(d%8==4) and 4 or 0};x=x+width;remaining=remaining-width
  end
  return result
 end
 local function fits(es,remove,c,allowed)
  local occupied={}
  for _,e in ipairs(es) do
   local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end
   local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
   for xx=x,x+w-1 do for yy=y,y+h-1 do local k=key(xx,yy);local owner=s.occupied[k]
    if occupied[k] or s.access[k] or owner and not remove[owner] or (a.face and xx<a.face) or (a.output_face and xx>a.output_face) then return false end;occupied[k]=true
   end end
   for _,o in ipairs(openings(e)) do local v=vectors[o.dir];local k=key(o.x+v[1],o.y+v[2])..'/'..((o.dir+8)%16)
    for _,old in ipairs(s.normal[k] or {}) do
     if not remove[old.index] and not s.removed[old.index] and compatible(o.categories,old.categories) and old.index~=s.nodes[c.left].index and old.index~=s.nodes[c.right].index and not(allowed and allowed[old.index])then return false end
    end
   end
  end
  return true
 end
 local function count_roles(cut,k,side)
  local n=s.nodes[k];cut.minx=math.min(cut.minx,n.x);cut.maxx=math.max(cut.maxx,n.x);cut.miny=math.min(cut.miny,n.y);cut.maxy=math.max(cut.maxy,n.y)
  for _,p in ipairs(s.roles[k] or {}) do
   if p.kind=='output' then cut[side..'_sources']=cut[side..'_sources']+1
   elseif p.kind=='input' then
    cut[side..'_sinks']=cut[side..'_sinks']+1
    if p.rate then cut[side..'_rate']=cut[side..'_rate']+p.rate else cut.known=false end
   end
  end
 end
 while s.index<=#s.candidates do
  work.phase('fmf',0.981,s.index..'/'..#s.candidates)
  local c=s.candidates[s.index]
  if not s.cut then
   if not work.consume(16) then return false end
   local remove,blocked={},{};local ok=not s.removed[s.nodes[c.left].index]and not s.removed[s.nodes[c.right].index]
   for _,k in ipairs(c.inside) do local n=s.nodes[k];remove[n.index]=true;blocked[k]=true;if s.removed[n.index] then ok=false end end
   if not ok then skip('overlap');s.index=s.index+1
   else s.cut={queue={c.left},seen={[c.left]=true},head=1,remove=remove,blocked=blocked,left_sources=0,right_sources=0,left_sinks=0,right_sinks=0,left_rate=0,right_rate=0,known=true,minx=math.huge,miny=math.huge,maxx=-math.huge,maxy=-math.huge} end
  end
  if s.cut then
   local cut=s.cut
   while not cut.left_seen and cut.queue[cut.head] do
    if not work.consume(8) then return false end
    local k=cut.queue[cut.head];cut.head=cut.head+1;count_roles(cut,k,'left');local ns={};for q in pairs(s.nodes[k].adj) do ns[#ns+1]=q end;table.sort(ns)
    for _,q in ipairs(ns) do if not cut.blocked[q] and not cut.seen[q] and not s.removed[s.nodes[q].index] then cut.seen[q]=true;cut.queue[#cut.queue+1]=q end end
   end
   if not cut.left_seen then cut.left_seen=cut.seen;cut.queue={c.right};cut.seen={[c.right]=true};cut.head=1 end
   while cut.queue[cut.head] do
    if not work.consume(8) then return false end
    local k=cut.queue[cut.head];cut.head=cut.head+1;count_roles(cut,k,'right');local ns={};for q in pairs(s.nodes[k].adj) do ns[#ns+1]=q end;table.sort(ns)
    for _,q in ipairs(ns) do if not cut.blocked[q] and not cut.seen[q] and not s.removed[s.nodes[q].index] then cut.seen[q]=true;cut.queue[#cut.queue+1]=q end end
   end
   if not cut.counted then
    if cut.left_seen[c.right] then skip('cycle');s.cut=nil;s.index=s.index+1
    else
     cut.counted=true
     local forward=cut.left_sources>0 and cut.right_sinks>0;local backward=cut.right_sources>0 and cut.left_sinks>0
     if not cut.known or forward==backward then skip('direction');s.cut=nil;s.index=s.index+1
     else
      cut.reverse=backward;cut.rate=backward and cut.left_rate or cut.right_rate
      local extent=a.catalog.ordinary_extent or 320
      if extent==0 or(cut.maxx-cut.minx+1<=extent and cut.maxy-cut.miny+1<=extent)then skip('not-required');s.cut=nil;s.index=s.index+1
      else cut.ordinary=cut.rate<=(a.catalog.pump_capacity or 0)+1e-8 end
      if s.cut and not cut.ordinary and cut.rate>a.catalog.limit+1e-8 then skip('capacity');s.cut=nil;s.index=s.index+1 end
     end
    end
   end
   if s.cut then
    if not cut.proposed then
     if not work.consume(16) then return false end
     if cut.ordinary then
      local middle=math.floor(#c.inside/2)
      for offset=0,#c.inside do local i=middle+((offset%2==0)and offset/2 or -(offset+1)/2)
       local n,m=s.nodes[c.inside[i]or''],s.nodes[c.inside[i+1]or'']
       if n and m and not n.ug and not m.ug and math.abs(n.x-m.x)+math.abs(n.y-m.y)==1 then
        local d=cut.reverse and(c.d+8)%16 or c.d;local v=vectors[d];local first=cut.reverse and m or n
        local up,down=key(first.x-v[1],first.y-v[2]),key(first.x+2*v[1],first.y+2*v[2])
        local remove={[n.index]=true,[m.index]=true};local allowed={}
        for _,k in ipairs({up,down})do if s.nodes[k]then allowed[s.nodes[k].index]=true end end
        local es={{name='pump',position={x=(n.x+m.x)/2+.5,y=(n.y+m.y)/2+.5},direction=d}}
        if s.nodes[up]and s.nodes[down]and fits(es,remove,c,allowed)then cut.proposed=es;cut.remove=remove;cut.upstream=up;cut.downstream=down;break end
       end
      end
     else
      for _,side in ipairs({1,-1}) do local es=make_bridge(c,cut.reverse,side);if fits(es,cut.remove,c) then cut.proposed=es;break end end
      cut.upstream=cut.reverse and c.right or c.left;cut.downstream=cut.reverse and c.left or c.right
     end
     if not cut.proposed then skip('space');s.cut=nil;s.index=s.index+1
     else
      for i,e in ipairs(cut.proposed) do e.entity_number=s.next_id+i-1 end
      cut.check={};cut.entities={};cut.assembly_index=1;cut.added_index=1
     end
    end
    if s.cut then
     while cut.assembly_index<=#a.entities do
      if not work.consume(4) then return false end
      local i=cut.assembly_index;cut.assembly_index=i+1
      if not s.removed[i] and not cut.remove[i] then cut.entities[#cut.entities+1]=a.entities[i] end
     end
     while cut.added_index<=#s.added do
      if not work.consume(4) then return false end
      cut.entities[#cut.entities+1]=s.added[cut.added_index];cut.added_index=cut.added_index+1
     end
     if not cut.assembled then for _,e in ipairs(cut.proposed) do cut.entities[#cut.entities+1]=e end;cut.assembled=true end
     local done,issues=graph.step({entities=cut.entities,ports=a.ports,independent=a.independent},cut.check)
     if not done then return false end
     if #issues>0 then skip('validation')
     else
      for i in pairs(cut.remove) do s.removed[i]=true end
      for _,k in ipairs(c.inside)do if cut.remove[s.nodes[k].index]then s.occupied[k]=nil end end
      s.roles[cut.upstream]=s.roles[cut.upstream]or{};s.roles[cut.upstream][#s.roles[cut.upstream]+1]={kind='input',rate=cut.rate}
      s.roles[cut.downstream]=s.roles[cut.downstream]or{};s.roles[cut.downstream][#s.roles[cut.downstream]+1]={kind='output',rate=cut.rate}
      for _,e in ipairs(cut.proposed) do s.added[#s.added+1]=e;add_index(e,-#s.added) end
      s.next_id=s.next_id+#cut.proposed;if cut.ordinary then s.stats.pumps=s.stats.pumps+1 else s.stats.bridges=s.stats.bridges+1 end
     end
     s.cut=nil;s.index=s.index+1
    end
   end
  end
 end
 -- Verify the remaining native segments: an unplaceable separator must not
 -- silently leave an over-extent pipeline in the finished blueprint.
 s.extent_seen=s.extent_seen or {};s.extent_index=s.extent_index or 1
 while s.extent_index<=#s.order do
  local k=s.order[s.extent_index]
  if s.extent_seen[k]or s.removed[s.nodes[k].index]then s.extent_index=s.extent_index+1
  else
   s.extent_scan=s.extent_scan or{queue={k},head=1,l=math.huge,t=math.huge,r=-math.huge,b=-math.huge};local scan=s.extent_scan;s.extent_seen[k]=true
   while scan.queue[scan.head]do
    if not work.consume(8)then return false end
    local q=scan.queue[scan.head];scan.head=scan.head+1;local n=s.nodes[q]
    scan.l=math.min(scan.l,n.x);scan.r=math.max(scan.r,n.x);scan.t=math.min(scan.t,n.y);scan.b=math.max(scan.b,n.y)
    for other in pairs(n.adj)do if not s.extent_seen[other]and not s.removed[s.nodes[other].index]then s.extent_seen[other]=true;scan.queue[#scan.queue+1]=other end end
   end
   local extent=a.catalog.ordinary_extent or 320
   if extent>0 and(scan.r-scan.l+1>extent or scan.b-scan.t+1>extent)then skip('extent')end
   s.extent_scan=nil;s.extent_index=s.extent_index+1
  end
 end
 s.final_result=s.final_result or {};s.final_index=s.final_index or 1
 while s.final_index<=#a.entities+#s.added do
  if not work.consume(4) then return false end
  local i=s.final_index;s.final_index=i+1;local e=i<=#a.entities and not s.removed[i] and a.entities[i] or i>#a.entities and s.added[i-#a.entities]
  if e then s.final_result[#s.final_result+1]=e;if e.name==a.catalog.pipe or e.name==a.catalog.underground then s.stats.ordinary=s.stats.ordinary+1 end end
 end
 return true,s.final_result,s.next_id,s.stats
end
work.register('fmf-promote',step)
function M.promote(entities,ports,en,settings,catalog)
 local l,t,r,b=math.huge,math.huge,-math.huge,-math.huge;local ordinary=0
 for _,e in ipairs(entities)do if e.name==catalog.pipe or e.name==catalog.underground then
  ordinary=ordinary+1;l=math.min(l,e.position.x);r=math.max(r,e.position.x);t=math.min(t,e.position.y);b=math.max(b,e.position.y)
 end end
 local extent=catalog.ordinary_extent or 320
 if ordinary==0 or extent==0 or(r-l+1<=extent and b-t+1<=extent)then
  return entities,en,{bridges=0,ordinary=ordinary,skipped={},not_required=true,junctions=0}
 end
 local es,id,status=work.operation('fmf-promote',nil,{entities=entities,ports=ports,en=en,catalog=catalog,independent=settings.link_mode=='independent',face=settings.external_face_x,output_face=settings.output_face_x})
 if status.bridges>0 then
  local joined;es,id,joined=topology.coalesce(es,ports,id,catalog,settings.link_mode=='independent')
  status.junctions=joined.junctions;status.transitions_removed=joined.transitions_removed;status.ordinary=0
  for _,e in ipairs(es)do if e.name==catalog.pipe or e.name==catalog.underground then status.ordinary=status.ordinary+1 end end
 end
 return es,id,status
end
return M
