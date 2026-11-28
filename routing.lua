-- Returned plans are read-only: failed searches never edit another route.
local M = {}
local work=require("generation_work")
local ug_pairing=require("ug_pairing")
local dirs = {{0,-1,0},{1,0,4},{0,1,8},{-1,0,12}}
local function key(x,y) return x .. ',' .. y end
local function state(x,y,d,locked) return key(x,y) .. ',' .. d .. ',' .. tostring(locked) end
local empty={}
local vectors={[0]=dirs[1],[4]=dirs[2],[8]=dirs[3],[12]=dirs[4]}
local function vector(d)
  local v=vectors[d];if v then return v[1],v[2] end
end

local function validate_plan(plan)
  -- Reject self-intersections and unintended adjacency before committing.
  local cells={}
  for i,e in ipairs(plan) do
    local k=key(e.x,e.y)
    if cells[k] then return false,'self-intersection' end
    cells[k]=i
  end
  for i,e in ipairs(plan) do
    if e.kind~='ug_in' then
      local dx,dy=vector(e.d); local j=cells[key(e.x+dx,e.y+dy)]
      if j and j~=i+1 then return false,'self-connection' end
    else
      local out=plan[i+1]
      if not out or out.kind~='ug_out' or out.d~=e.d then return false,'unpaired-tunnel' end
      local dx,dy=vector(e.d)
      local length=math.abs(out.x-e.x)+math.abs(out.y-e.y)
      for offset=1,length-1 do
        local j=cells[key(e.x+dx*offset,e.y+dy*offset)]
        local mouth=j and plan[j]
        if mouth and mouth.d%8==e.d%8 and (mouth.kind=='ug_in' or mouth.kind=='ug_out') then
          return false,'self-tunnel-conflict'
        end
      end
    end
  end
  return true
end

-- Obstacle-free lower bound with the same 90-degree turn cost as search.
-- A forced underground exit must first continue straight on the surface.
local function estimate(n,tx,ty)
 local x,y=n.x,n.y;local extra=0
 if x==tx and y==ty then return 0 end
 if n.locked then local dx,dy=vector(n.d);x=x+dx;y=y+dy;extra=1 end
 local dx,dy=tx-x,ty-y;local distance=math.abs(dx)+math.abs(dy)
 if distance==0 then return extra end
 local vx,vy=vector(n.d);local forward=dx*vx+dy*vy
 local turns
 if dx~=0 and dy~=0 then turns=forward>0 and 1 or 2
 elseif forward>0 then turns=0
 elseif forward<0 then turns=3;distance=distance+2
 else turns=1 end
 return extra+distance+6*turns
end

local function search_step(o,saved)
  local occupied,cell=o.occupied,o.cell
  if o.context then
    local c=o.context
    occupied=function(x,y)
      local k=key(x,y);local value=c.occupied[k]
      if value then return value end
      for owner in pairs(c.endpoint_reservations[k] or empty) do
        if owner~=c.source_key and owner~=c.target_key and owner~=c.source_reservation and owner~=c.target_reservation then return 'reserved' end
      end
      return c.routing_producers and c.reserved_taps[k] and 'reserved' or nil
    end
    cell=function(x,y)
      local k=key(x,y);local kind=c.cell_kind[k]
      return c.cell_dir[k],kind,(kind=='ug_in' or kind=='ug_out') and ((c.ug_names or empty)[k] or c.ug_name) or nil
    end
  end
  -- Context is immutable for a suspended search. Reuse native-cell lookups
  -- across directional states and candidate tunnel lengths.
  if o.context then
   local raw_cell=cell;local rows=saved.cell_cache or {};saved.cell_cache=rows
   cell=function(x,y)
    local row=rows[x];if not row then row={};rows[x]=row end
    local value=row[y]
    if not value then local d,kind,tier=raw_cell(x,y);value={d,kind,tier};row[y]=value end
    return value[1],value[2],value[3]
   end
  end
  local sx,sy,tx,ty=o.sx,o.sy,o.tx,o.ty
  local margin=o.margin or 24
  local xmin,xmax=math.min(sx,tx)-margin,math.max(sx,tx)+margin
  local ymin,ymax=math.min(sy,ty)-margin,math.max(sy,ty)+margin
  local extent=o.context and o.context.layout_bounds
  if extent then
    xmin=math.min(xmin,extent.left-3);xmax=math.max(xmax,extent.right+3)
    ymin=math.min(ymin,extent.top-3);ymax=math.max(ymax,extent.bottom+3)
  end
  if o.min_y then ymin=math.max(ymin,o.min_y) end
  if o.max_y then ymax=math.min(ymax,o.max_y) end
  if o.max_x then xmax=math.min(xmax,o.max_x) end
  local function footprint_free(x,y)
    local c=o.context;if not c then return true end
    local k=key(x,y)
    -- Empty space between protected production blocks remains a usable corridor.
    local owner=(c.block_cells or empty)[k]
    if owner then
      local a=c.port_access or empty
      local own=(owner==c.source_owner or owner==c.target_owner) and not (c.machine_cells or empty)[k]
      if not own and not ((a[c.source_key] or empty)[k] or (a[c.target_key] or empty)[k]) then return false end
    end
    return true
  end
  local function free(x,y)
    if not footprint_free(x,y) then return false end
    if x==sx and y==sy then return true end
    if x==tx and y==ty then return o.target_free end
    return occupied(x,y)==nil
  end
  local function tunnel_forbidden(x,y)
    local c=o.context;if not c then return false end
    local k=key(x,y);local owner=(c.block_cells or empty)[k]
    if not owner or owner==c.source_owner or owner==c.target_owner then return false end
    local access=c.port_access or empty
    return not ((access[c.source_key] or empty)[k] or (access[c.target_key] or empty)[k])
  end
  local function in_bounds(x,y)
    local minimum=math.max(xmin,o.min_x or xmin)
    local entry=o.entry_x and y==sy and x>=o.entry_x and x<minimum
    return (x>=minimum or entry) and x<=xmax and y>=ymin and y<=ymax
  end
  local sdx,sdy=vector(o.start_dir)
  -- A surface belt must neither collect a foreign belt nor point into one.
  local function safe(x,y,d,px,py,kind)
    local dx,dy=vector(d)
    for _,v in ipairs(dirs) do
      local nx,ny=x+v[1],y+v[2]
      if not (nx==px and ny==py) then
        local nd,nkind=cell(nx,ny)
        if nd~=nil then
          local ex,ey=vector(nd)
          local feeds=nkind~='ug_in' and nx+ex==x and ny+ey==y
          local own_header=o.context and o.context.source_owner and (o.context.block_cells or empty)[key(nx,ny)]==o.context.source_owner
          local source_feed=x==sx and y==sy and ((nx==sx-sdx and ny==sy-sdy) or own_header)
          -- A merged production outlet needs the full surface belt. Turning
          -- that cell into a tunnel entrance can hide the side-fed lane.
          if feeds and kind=='ug_in'and nd~=d then return false end
          if feeds and not source_feed then return false end
        end
      end
    end
    if kind~='ug_in' then
      if o.context and not (x==tx and y==ty) and not (x+dx==tx and y+dy==ty) then
        local c=o.context
        for owner in pairs((c.endpoint_reservations or empty)[key(x+dx,y+dy)] or empty) do
          if owner~=c.source_key and owner~=c.target_key and owner~=c.source_reservation and owner~=c.target_reservation then return false end
        end
      end
      local nd=cell(x+dx,y+dy)
      if nd~=nil and not (x==tx and y==ty) and not (x+dx==tx and y+dy==ty) then return false end
    end
    return true
  end
  local function jump_safe(x,y,ox,oy,d)
    local dx,dy=vector(d)
    return ug_pairing.safe(cell,x,y,dx,dy,math.abs(ox-x)+math.abs(oy-y),d,o.ug_name,o.max_distance or 0)
  end
  -- Necessary endpoint conditions. A larger search rectangle cannot repair
  -- these, so do not explore thousands of states before discovering them.
  if not saved.heap and (sx~=tx or sy~=ty) then
    if not footprint_free(sx,sy) then return true,nil,'blocked-source-footprint' end
    if not footprint_free(tx,ty) then return true,nil,'blocked-target-footprint' end
    if not o.target_free then return true,nil,'blocked-target' end
    local surface=free(sx+sdx,sy+sdy) and safe(sx,sy,o.start_dir,nil,nil,'belt')
    local tunnel=o.start_tunnel and safe(sx,sy,o.start_dir,nil,nil,'ug_in')
    if not in_bounds(sx+sdx,sy+sdy) or not (surface or tunnel) then return true,nil,'blocked-source' end
    local feeders=0
    for _,v in ipairs(dirs) do
      local x,y=tx+v[1],ty+v[2];local d,kind=cell(x,y)
      if d~=nil and kind~='ug_in' then
        local dx,dy=vector(d)
        if x+dx==tx and y+dy==ty then
          feeders=feeders+1
          if not free(x,y) or d==(o.final_dir+8)%16 then return true,nil,'blocked-target-feed' end
        end
      end
    end
    if feeders>1 then return true,nil,'blocked-target-feeds' end
    -- Every valid surface arrival needs a free predecessor. A tunnel arrival
    -- must use the final direction and a legal pair outside production cells.
    local approach=false
    for _,v in ipairs(dirs) do
      local x,y=tx-v[1],ty-v[2]
      if v[3]~=(o.final_dir+8)%16 and in_bounds(x,y) and free(x,y) then approach=true;break end
    end
    if not approach and not tunnel_forbidden(tx,ty) then
      local dx,dy=vector(o.final_dir)
      for length=2,o.max_distance or 0 do
        local x,y=tx-dx*length,ty-dy*length
        if in_bounds(x,y) and free(x,y) and not tunnel_forbidden(x,y) and not tunnel_forbidden(x+dx,y+dy)
          and jump_safe(x,y,tx,ty,o.final_dir) then approach=true;break end
      end
    end
    if not approach then return true,nil,'blocked-target-approach' end
  end
  -- A Manhattan estimate points straight through a protected production group.
  -- Find the geometric distance around footprints once, ignoring belts (which
  -- may be crossed by a necessary tunnel). This also rejects sealed regions
  -- before spending thousands of directional belt-search states.
  if o.context and o.context.block_cells and not saved.footprint_ready then
    local q=saved.footprint_queue or {{x=tx,y=ty}}
    local distances=saved.footprint_distances or {[key(tx,ty)]=0}
    local head=saved.footprint_head or 1
    saved.footprint_queue=q;saved.footprint_distances=distances
    while head<=#q and distances[key(sx,sy)]==nil do
      if not work.consume(1) then saved.footprint_head=head;return false end
      local p=q[head];head=head+1;local distance=distances[key(p.x,p.y)]+1
      for _,v in ipairs(dirs) do local x,y=p.x+v[1],p.y+v[2];local k=key(x,y)
        if distances[k]==nil and in_bounds(x,y) and (footprint_free(x,y) or not tunnel_forbidden(x,y)) then
          distances[k]=distance;q[#q+1]={x=x,y=y}
        end
      end
    end
    saved.footprint_ready=true;saved.footprint_radius=distances[key(sx,sy)];saved.footprint_queue=nil;saved.footprint_head=nil
    if distances[key(sx,sy)]==nil then return true,nil,'sealed-footprint-region' end
  end
  local heap=saved.heap or {}
  local function before(a,b)
    if a.priority~=b.priority then return a.priority<b.priority end
    -- Prefer progress towards the target on equal lower bounds. Otherwise a
    -- clear rectangular area becomes a large Dijkstra plateau.
    if a.cost~=b.cost then return a.cost>b.cost end
    return a.order<b.order
  end
  local function push(n)
    saved.order=(saved.order or 0)+1;n.order=saved.order
    local lower=estimate(n,tx,ty)
    if saved.footprint_distances then lower=math.max(lower,saved.footprint_distances[key(n.x,n.y)] or saved.footprint_radius or 0) end
    n.priority=n.cost+(o.heuristic==false and 0 or (o.heuristic_weight or 1)*lower)
    heap[#heap+1]=n
    local i=#heap
    while i>1 do
      local p=math.floor(i/2)
      if not before(n,heap[p]) then break end
      heap[i]=heap[p]; i=p
    end
    heap[i]=n
  end
  local function pop()
    local n=heap[1]; local tail=table.remove(heap)
    if #heap>0 then
      local i=1
      while i*2<=#heap do
        local j=i*2
        if j<#heap and before(heap[j+1],heap[j]) then j=j+1 end
        if not before(heap[j],tail) then break end
        heap[i]=heap[j]; i=j
      end
      heap[i]=tail
    end
    return n
  end
  local first=saved.first or {x=sx,y=sy,d=o.start_dir,locked=true,cost=0}
  local best=saved.best or {[state(sx,sy,first.d,true)]=0}
  if not saved.heap then push(first) end
  local explored=saved.explored or 0
  saved.heap=heap;saved.first=first;saved.best=best
  -- Expansion includes directional checks and candidate tunnel mouths.
  local expansion_cost=4*(8+math.min(o.max_distance or 0,24))
  while #heap>0 and explored<(o.max_states or 60000) do
    if not work.consume(expansion_cost) then saved.explored=explored;return false end
    local n=pop(); local nk=state(n.x,n.y,n.d,n.locked)
    if n.cost==best[nk] then
      if not work.route_visit() then return true,nil,'layout-search-limit' end
      explored=explored+1
      if n.x==tx and n.y==ty and n.d~=(o.final_dir+8)%16 and (not n.locked or n.d==o.final_dir)
          and safe(tx,ty,o.final_dir,n.prev and n.prev.x,n.prev and n.prev.y,n.locked and 'ug_out' or 'belt') then
        local reversed={}; local cur=n
        while cur do reversed[#reversed+1]=cur; cur=cur.prev end
        local plan={}
        for i=#reversed,1,-1 do
          local a=reversed[i]; local b=reversed[i-1]
          local kind=a.locked and a~=first and 'ug_out' or 'belt'
          if b and b.jump then kind='ug_in' end
          plan[#plan+1]={x=a.x,y=a.y,d=b and b.d or o.final_dir,kind=kind}
        end
        local valid,reason=validate_plan(plan)
        if valid then return true,plan end
        if not o.avoid_cycles and not o.exhaustive and reason:find('^self') then return true,nil,reason end
        saved.rejected_goal=reason
      end
      if n.x~=tx or n.y~=ty then
      for _,v in ipairs(dirs) do
        local dx,dy,d=v[1],v[2],v[3]
        local allowed=(not n.locked or d==n.d) and d~=(n.d+8)%16
        if o.no_up and d==0 then allowed=false end
        if o.no_east and d==4 then allowed=false end
        if allowed then
          local function relax(x,y,locked,jump,cost)
            if not in_bounds(x,y) or not free(x,y) then return end
            if x==tx and y==ty and d==(o.final_dir+8)%16 then return end
            if o.avoid_cycles then
              local child,ancestor=nil,n
              while ancestor do
                if ancestor.x==x and ancestor.y==y then return end
                if child and not child.jump then
                  local ax,ay=vector(child.d)
                  if ancestor.x+ax==x and ancestor.y+ay==y then return end
                end
                child=ancestor;ancestor=ancestor.prev
              end
            end
            local k=state(x,y,d,locked)
            -- Prefer staying around the two related groups, without inventing
            -- impassable walls across their empty enclosing rectangles.
            if o.context then
              local c=o.context;local length=math.abs(x-n.x)+math.abs(y-n.y)
              for step=1,length do local cluster=(c.cluster_cells or empty)[key(n.x+dx*step,n.y+dy*step)]
                if cluster and cluster~=c.source_cluster and cluster~=c.target_cluster then cost=cost+3 end
              end
            end
            local total=n.cost+cost
            if best[k]==nil or total<best[k] then
              best[k]=total
              push({x=x,y=y,d=d,locked=locked,jump=jump,cost=total,prev=n})
            end
          end
          local px,py=n.prev and n.prev.x,n.prev and n.prev.y
          if safe(n.x,n.y,d,px,py,n.locked and n~=first and 'ug_out' or 'belt') then
            relax(n.x+dx,n.y+dy,false,false,d==n.d and 1 or 7)
          end
          -- An output must continue on the surface before a new tunnel input.
          if (not n.locked or (n==first and o.start_tunnel)) and d==n.d and safe(n.x,n.y,d,px,py,'ug_in') then
            local preserve=o.avoid_empty_tunnels==true or (o.avoid_empty_tunnels=='after-output' and n.prev and n.prev~=first and n.prev.locked)
            local needed=not preserve or not safe(n.x,n.y,d,px,py,'belt')
            local clear=not tunnel_forbidden(n.x,n.y) and not tunnel_forbidden(n.x+dx,n.y+dy)
            for len=2,clear and (o.max_distance or 0) or 0 do
              local ix,iy=n.x+dx*(len-1),n.y+dy*(len-1)
              if not needed and (not free(ix,iy) or not safe(ix,iy,d,ix-dx,iy-dy,'belt')) then needed=true end
              local ox,oy=n.x+dx*len,n.y+dy*len
              if tunnel_forbidden(ox,oy) then break end
              if needed and free(ox,oy) and jump_safe(n.x,n.y,ox,oy,d)
                  and safe(ox,oy,d,nil,nil,'ug_out') then
                relax(ox,oy,true,true,len+3)
              end
            end
          end
        end
      end
      end
    end
  end
  return true,nil,explored>=(o.max_states or 60000) and 'search-limit' or saved.rejected_goal or 'no-path'
end
work.register('belt-search',search_step)
function M.plan(o)
  local function run(options)
    if options.context then return work.operation('belt-search',nil,options,true) end
    return work.operation('belt-search',function(saved)return search_step(options,saved)end,nil,true)
  end
  local plan,reason=run(o)
  -- Path-dependent tunnel checks can reject a tied goal. Retain the established
  -- search as a rare fallback, without charging every successful route twice.
  if not plan and not o.shallow and o.heuristic~=false and reason and reason:find('^self') then
    local fallback={};for k,v in pairs(o) do fallback[k]=v end;fallback.avoid_cycles=true
    local repaired=run(fallback)
    if repaired then return repaired end
    fallback.avoid_cycles=nil;fallback.exhaustive=true;fallback.heuristic=false
    return run(fallback)
  end
  return plan,reason
end
return M
