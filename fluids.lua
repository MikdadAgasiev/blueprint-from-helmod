-- Fluid routing uses prototype connection positions and directions, never template sides.
local M={}
local work=require("generation_work")
local pipe_pair=require("pipe_pair")
local capacity=require('capacity')
local goal_distance=require('goal_distance')
local pipe_intervals=require('pipe_intervals')
local boundaries=require('block_boundaries')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local dirs={0,4,8,12}
local function key(x,y)return x..','..y end
-- Parallel underground pairs cannot share a pipe corridor. Keep every machine
-- port available before another fluid claims a tunnel through its mouth.
local function port_clear(ports,x,y,xx,yy,group)
 if not ports then return true end
 local horizontal=y==yy
 local list=horizontal and ports.horizontal[y] or ports.vertical[x]
 local a,b=horizontal and x or y,horizontal and xx or yy
 for _,p in ipairs(list or {}) do
  if p.group~=group and p.value>math.min(a,b) and p.value<math.max(a,b) then return false end
 end
 return true
end
-- Underground mouths expose only their facing surface side. Their other
-- neighbours may carry different fluids without making a connection.
local function neighbor_conflict(network,reserved,nx,ny,x,y,g)
 local k=key(nx,ny);local n=network[k]
 if n then
  if n.group==g then return false end
  if n.dir==nil then return true end
  local v=vectors[n.dir]
  return nx+v[1]==x and ny+v[2]==y
 end
 return reserved[k]~=nil and reserved[k]~=g
end
function M.ports(entities,blocks)
 local ports,issues={},{}
 local by_id={};local needs_index=false
 for _,b in ipairs(blocks) do if b.machine_ids then needs_index=true;break end end
 if needs_index then for _,e in ipairs(entities) do if e.entity_number then by_id[e.entity_number]=e end end end
 for bi,b in ipairs(blocks) do
  local machines={}
  if b.machine_ids then
   local seen={};for _,id in ipairs(b.machine_ids) do if by_id[id] then machines[#machines+1]=by_id[id];seen[id]=true end end
   -- Equipment/module metadata excludes recipe-less fluid sources.
   for ei=b.entity_first,b.entity_last do local e=entities[ei]
    if e and prototypes.entity[e.name].type=='offshore-pump' and not seen[e.entity_number] then machines[#machines+1]=e end
   end
  else for ei=b.entity_first,b.entity_last do if entities[ei] then machines[#machines+1]=entities[ei] end end end
  local machine_counts={};for _,e in ipairs(machines) do
   local name=e.recipe or (prototypes.entity[e.name].type=='offshore-pump' and e.name)
   if name then machine_counts[name]=(machine_counts[name] or 0)+1 end
  end
  for _,e in ipairs(machines) do
   local ep=prototypes.entity[e.name]
   if (e.recipe or ep.type=='offshore-pump') and ep.fluidbox_prototypes then
    -- Offshore pumps have no recipe on the blueprint entity. Their planned
    -- fluid product still needs a real output port in the routed network.
    local recipe=e.recipe and prototypes.recipe[e.recipe] or b.recipe_node
    for _,side in ipairs({'ingredients','products'}) do
     local kind=side=='ingredients' and 'input' or 'output'
     local eligible,fluids={},{}
     for _,fb in pairs(ep.fluidbox_prototypes) do
      if fb.production_type==kind or fb.production_type=='input-output' then eligible[#eligible+1]=fb end
     end
     table.sort(eligible,function(a,b)return a.index<b.index end)
     for _,item in ipairs(recipe[side]) do
      if item.type=='fluid' then fluids[#fluids+1]=item end
     end
     -- Factorio divides automatic boxes into consecutive groups, assigning one
     -- extra box to each of the first fluids until the remainder runs out.
     -- Explicit indices address one box; optional extra openings aren't needed.
     local group_size=math.floor(#eligible/math.max(1,#fluids))
     local extra_boxes=#eligible%math.max(1,#fluids)
     local next_box=1
     for i,item in ipairs(fluids) do
      local explicit=item.fluidbox_index and item.fluidbox_index>0
      local first=explicit and item.fluidbox_index or next_box
      local count=explicit and 1 or group_size+(i<=extra_boxes and 1 or 0)
      if not explicit then next_box=next_box+count end
      local connected=false
      for index=first,first+count-1 do
       local chosen=eligible[index]
       if not chosen then break end
       for _,c in ipairs(chosen.pipe_connections) do
        if c.connection_type=='normal' then
         local rot=e.direction or 0;local pos=c.positions[rot/4+1]
         local dir=(c.direction+rot)%16;local v=vectors[dir]
         if pos and v then
          connected=true
          local rate
          local node=b.recipe_node
          if node then for _,flow in pairs(node[side] or {}) do if flow.type=='fluid' and flow.name==item.name and (type(flow.count)=='number' or type(flow.amount)=='number') then rate=capacity.flow(flow,node)/(machine_counts[e.recipe or e.name] or 1);break end end end
          ports[#ports+1]={x=math.floor(e.position.x+pos.x+v[1]),y=math.floor(e.position.y+pos.y+v[2]),dir=dir,categories=c.connection_category,fluid=item.name,kind=kind,rate=rate,box=chosen.index,machine=e.entity_number,block=bi}
          break
         end
        end
       end
       if connected then break end
      end
      if not connected then issues[#issues+1]="[BFH-fluid] FAIL no compatible port: "..e.name.."/"..(e.recipe or 'source').."/"..item.name end
     end
    end
   end
  end
 end
 return ports,issues
end
-- Reserve the local fan-out before packing, rather than letting a solid
-- inlet and several adjacent fluid mouths compete for the same narrow gap.
function M.layout_clearance(blocks,ports)
 for _,p in ipairs(ports) do local b=blocks[p.block];local v=vectors[p.dir]
  if b and v then
   local x,y=p.x+v[1]*3,p.y+v[2]*3
   local right,bottom=b.layout_left+b.layout_width,b.layout_top+b.layout_height
   b.layout_left=math.min(b.layout_left,x);b.layout_top=math.min(b.layout_top,y)
   b.layout_width=math.max(right,x+1)-b.layout_left;b.layout_height=math.max(bottom,y+1)-b.layout_top
  end
 end
end
-- Keep enough straight approach for a turn or an underground landing before
-- each solid port. One free cell can still be fenced into a blind pocket.
function M.solid_clearance(entities,blocks,ports)
 local directions,fluid_ports,result={},{},{}
 for _,p in ipairs(ports) do fluid_ports[key(p.x,p.y)]=true end
 for _,e in ipairs(entities) do local p=prototypes.entity[e.name]
  if p.type=='transport-belt' or p.type=='underground-belt' or p.type=='splitter' then
   local w,h=p.tile_width,p.tile_height;if (e.direction or 0)%8==4 then w,h=h,w end
   local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
   for xx=x,x+w-1 do for yy=y,y+h-1 do directions[key(xx,yy)]=e.direction or 0 end end
  end
 end
 local function reserve(p,sign)
  if not p then return end
  local d=directions[key(p.x,p.y)] or p.direction
  local v=vectors[d];if not v then return end
  for step=1,3 do
   local k=key(p.x+v[1]*sign*step,p.y+v[2]*sign*step)
   if not fluid_ports[k] then result[k]=true end
  end
 end
 for _,b in ipairs(blocks) do
  for _,p in ipairs(b.inputs or {}) do if not p.array_local then reserve(p,-1) end end
  reserve(b.product_out,1)
  for _,p in ipairs(b.output_ports or {}) do reserve(p,1) end
  for _,p in pairs(b.product_outs or {}) do reserve(p,1) end
 end
 return result
end
function M.reserve(entities,ports,en,pipe)
 for _,p in ipairs(ports) do
  entities[#entities+1]={entity_number=en,name=pipe,position={x=p.x+0.5,y=p.y+0.5},tags={bfh_fluid_reservation=true}};en=en+1
 end
 return en
end
local function search_step(args,saved)
 local p,targets=args.p,args.targets
 local occupied,network,reserved,tunnels=args.occupied,args.network,args.reserved,args.tunnels
 local external_access,face_x=args.external_access,args.face_x
 local xmin,xmax,ymin,ymax,maxdist=args.xmin,args.xmax,args.ymin,args.ymax,args.maxdist
 local function free(x,y,g,surface_dir)
  if args.output_face_x and x>args.output_face_x then return false end
  if face_x and x<face_x+2 and external_access[key(x,y)]~=g then return false end
  local k=key(x,y)
  if (network[k] and network[k].dir~=nil) or occupied[k] or (reserved[k] and reserved[k]~=g) or (network[k] and network[k].group~=g) then return false end
  for _,d in ipairs(dirs) do if surface_dir==nil or surface_dir==d then local v=vectors[d];if neighbor_conflict(network,reserved,x+v[1],y+v[2],x,y,g) then return false end end end
  return true
 end
 if not saved.tunnel_index then saved.tunnel_index=pipe_intervals.build(tunnels) end
 local function tunnel_ok(x,y,xx,yy) return pipe_intervals.clear(saved.tunnel_index,x,y,xx,yy) and port_clear(args.port_mouths,x,y,xx,yy,p.group) end
 local function mouth_ok(x,y,d)
  local k=key(x,y);local required=args.port_directions and args.port_directions[k]
  return not (args.required_surface and args.required_surface[k]) and (required==nil or required==d)
 end
  local g=p.group;local heap=saved.heap or {};local dist,parent=saved.dist or {},saved.parent or {}
  local availability=saved.availability or {}
  local function available(x,y,surface_dir)
    local k=key(x,y)..(surface_dir and ('/'..surface_dir) or '')
    if availability[k]==nil then availability[k]=free(x,y,g,surface_dir) end
    return availability[k]
  end
  if not saved.goal_tree then
   local points={}
   for k in pairs(targets) do local x,y=k:match('^(-?%d+),(-?%d+)$');points[#points+1]={tonumber(x),tonumber(y)} end
   saved.goal_tree=goal_distance.build(points)
  end
  -- Prefer progress toward a real connection over exhaustive cheap tunnel detours.
  -- This weighted search still validates every surface opening and tunnel.
  local function heuristic(x,y) return goal_distance.distance(saved.goal_tree,x,y)*(args.heuristic_weight or 16) end
  local function push(n)
   n.priority=n.cost+heuristic(n.x,n.y)
   local i=#heap+1;heap[i]=n
   while i>1 do local a=math.floor(i/2);if heap[a].priority<=n.priority then break end;heap[i]=heap[a];i=a;heap[i]=n end
  end
  local function pop()
   local first=heap[1];local last=table.remove(heap);if #heap>0 then
    local i=1;heap[1]=last
    while i*2<=#heap do local c=i*2;if heap[c+1] and heap[c+1].priority<heap[c].priority then c=c+1 end;if heap[c].priority>=last.priority then break end;heap[i]=heap[c];i=c;heap[i]=last end
   end;return first
  end
  local sk=key(p.x,p.y)
  if not saved.heap then dist[sk]=0;push{x=p.x,y=p.y,cost=0} end
  saved.heap=heap;saved.dist=dist;saved.parent=parent;saved.availability=availability
  local visits=saved.visits or 0
  while #heap>0 do
   if not work.consume(16+8*math.min(maxdist,64)) then saved.visits=visits;return false end
   local n=pop();local k=key(n.x,n.y)
   if n.cost==dist[k] then
    if not work.route_visit() then return true end
    visits=visits+1;if visits>100000 then return true end
    if targets[k] then
     local path={};while k~=sk do local a=parent[k];path[#path+1]=a;k=a.from end
     return true,path
    end
    local history
    local function offer(x,y,cost,edge)
     if x<xmin-24 or x>xmax+24 or y<ymin-24 or y>ymax+24 or not available(x,y) then return end
     local q=key(x,y);local nc=n.cost+cost
     if dist[q] and nc>=dist[q] then return end
     if edge.ax then
      local mouth_at_start=(edge.ax==p.x and edge.ay==p.y)
      local end_at_start=(edge.bx==p.x and edge.by==p.y)
      if end_at_start or (mouth_at_start and not (k==sk and edge.dir==p.dir)) then return end
     end
     -- A pending tunnel mouth cannot also serve as a surface junction.
     -- Existing-network occupancy alone misses overlaps within this new path.
     -- All offers from this node share the same ancestry. Build its exact
     -- occupancy once instead of walking the whole path for every tunnel.
     if not history then
      history={points={},mouths={},segments={}};local cursor=k
      while cursor~=sk do local old=parent[cursor]
       history.points[key(old.x,old.y)]=true
       if old.ax then
        history.mouths[key(old.ax,old.ay)]=true;history.mouths[key(old.bx,old.by)]=true
        history.segments[#history.segments+1]={x=old.ax,y=old.ay,xx=old.bx,yy=old.by}
       end
       cursor=old.from
      end
      history.index=pipe_intervals.build(history.segments);history.segments=nil
     end
     if history.mouths[q]then return end
     if edge.ax then
      local a,b=key(edge.ax,edge.ay),key(edge.bx,edge.by)
      if history.mouths[a]or history.mouths[b]or history.points[a]or history.points[b]
       or not pipe_intervals.clear(history.index,edge.ax,edge.ay,edge.bx,edge.by)then return end
     end
     if not dist[q] or nc<dist[q] then dist[q]=nc;edge.from=k;edge.x=x;edge.y=y;parent[q]=edge;push{x=x,y=y,cost=nc} end
    end
    for _,d in ipairs(dirs) do
     local v=vectors[d];local dx,dy=v[1],v[2]
     offer(n.x+dx,n.y+dy,1,{})
     local first_start=(k==sk and d==p.dir) and 0 or 1
     for start=first_start,1 do
      local ax,ay=n.x+dx*start,n.y+dy*start
      if not network[key(ax,ay)] and mouth_ok(ax,ay,(d+8)%16) and available(ax,ay,(d+8)%16) then
       for length=2,maxdist do
        local bx,by=ax+dx*length,ay+dy*length
        if not network[key(bx,by)] and mouth_ok(bx,by,d) and available(bx,by,d) and tunnel_ok(ax,ay,bx,by) then
         offer(bx+dx,by+dy,3+length*0.15,{ax=ax,ay=ay,bx=bx,by=by,dir=d})
        end
       end
      end
     end
    end
   end
  end
  return true
end
work.register('fluid-search',search_step)
function M.route(entities,ports,en,settings,report)
 -- Remove temporary port reservations, retaining solid routing.
 for i=#entities,1,-1 do if entities[i].tags and entities[i].tags.bfh_fluid_reservation then table.remove(entities,i) end end
 if #ports==0 then report('[BFH-fluid] Ports=0; failures=0');return en,0 end
 local occupied,network,reserved,tunnels={},{},{},{}
 local xmin,ymin,xmax,ymax=math.huge,math.huge,-math.huge,-math.huge
 for _,e in ipairs(entities) do
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if e.direction==4 or e.direction==12 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+0.001),math.floor(e.position.y-h/2+0.001)
  for a=x,x+w-1 do for b=y,y+h-1 do occupied[key(a,b)]=true end end
  xmin=math.min(xmin,x);ymin=math.min(ymin,y);xmax=math.max(xmax,x+w);ymax=math.max(ymax,y+h)
 end
 for k in pairs(settings.fluid_belt_clearance or {}) do occupied[k]=true end
 local groups,order={},{};local port_directions,required_surface={},{};local port_mouths={horizontal={},vertical={}}
 local external_access={}
 for _,p in ipairs(ports) do
  p.group=p.fluid..(settings.link_mode=='independent' and ('/'..p.block) or '')
  local horizontal=(p.dir or 0)%8==4
  local lines=horizontal and port_mouths.horizontal or port_mouths.vertical
  local line=horizontal and p.y or p.x;lines[line]=lines[line] or {}
  lines[line][#lines[line]+1]={value=horizontal and p.x or p.y,group=p.group}
  reserved[key(p.x,p.y)]=p.group;port_directions[key(p.x,p.y)]=((p.dir or 0)+8)%16
  if p.external then
    local v=vectors[p.dir or 4];local sign=p.terminal and -1 or 1
    local x,y=p.x+v[1]*sign,p.y+v[2]*sign
    external_access[key(p.x,p.y)]=p.group;external_access[key(x,y)]=p.group
    reserved[key(x,y)]=p.group
    -- Same-side outputs use a separate zone below the input interface.
    if p.terminal and settings.external_face_x and p.x<settings.external_face_x+2 then
      for xx=p.x,settings.external_face_x+2 do external_access[key(xx,p.y)]=p.group end
    end
  end
  if not groups[p.group] then groups[p.group]={};order[#order+1]=p.group end
  groups[p.group][#groups[p.group]+1]=p
 end
 -- Route scarce networks first. A single isolated acid/water source has no
 -- alternate anchor when the many refinery ports surround its last opening.
 table.sort(order,function(a,b)
  if #groups[a]~=#groups[b] then return #groups[a]<#groups[b] end
  return a<b
 end)
 local failures=0
 local pipe=settings.pipe or 'pipe'
 local ug,maxdist,reason=pipe_pair.resolve(pipe)
 if not ug and #ports>0 then report('[BFH-fluid] Surface-only routing: '..pipe..'; '..reason) end
 local function free(x,y,g,surface_dir)
  if settings.output_face_x and x>settings.output_face_x then return false end
  if settings.external_face_x and x<settings.external_face_x+2 and external_access[key(x,y)]~=g then return false end
  local k=key(x,y)
  if (network[k] and network[k].dir~=nil) or occupied[k] or (reserved[k] and reserved[k]~=g) or (network[k] and network[k].group~=g) then return false end
  for _,d in ipairs(dirs) do if surface_dir==nil or surface_dir==d then local v=vectors[d];if neighbor_conflict(network,reserved,x+v[1],y+v[2],x,y,g) then return false end end end
  return true
 end
 local function tunnel_ok(x,y,xx,yy,g)
  if not port_clear(port_mouths,x,y,xx,yy,g) then return false end
  for _,t in ipairs(tunnels) do
   if x==xx and t.x==t.xx and x==t.x and math.max(math.min(y,yy),math.min(t.y,t.yy))<=math.min(math.max(y,yy),math.max(t.y,t.yy)) then return false end
   if y==yy and t.y==t.yy and y==t.y and math.max(math.min(x,xx),math.min(t.x,t.xx))<=math.min(math.max(x,xx),math.max(t.x,t.xx)) then return false end
  end
  return true
 end
 local function add(x,y,g,dir)
  local k=key(x,y);if network[k] then return end
  entities[#entities+1]={entity_number=en,name=dir and ug or pipe,position={x=x+0.5,y=y+0.5},direction=dir or 0};en=en+1
  network[k]={group=g,dir=dir}
 end
 local function search(p,targets)
  return work.operation('fluid-search',nil,{p=p,targets=targets,occupied=occupied,
    network=network,reserved=reserved,tunnels=tunnels,external_access=external_access,port_mouths=port_mouths,port_directions=port_directions,required_surface=required_surface,
    face_x=settings.external_face_x,output_face_x=settings.output_face_x,xmin=xmin,xmax=xmax,ymin=ymin,ymax=ymax,maxdist=maxdist,heuristic_weight=settings.layout_search=='thorough' and .4 or 16},true)
 end
 -- A short straight landing may be a dead-end pocket between two blocks.
 -- Keep such ports uncommitted so the full search can choose another escape.
 local function open_landing(x,y,bx,by,ax,ay,g)
  local q={{x=x,y=y}};local seen={[key(x,y)]=true};local head=1
  while q[head] and head<=8 do
   local p=q[head];head=head+1
   local n=network[key(p.x,p.y)]
   if n and n.group==g and n.dir==nil then return true end
   for _,d in ipairs(dirs) do local v=vectors[d];local xx,yy=p.x+v[1],p.y+v[2];local k=key(xx,yy)
    if not seen[k] and not (xx==bx and yy==by) and not (xx==ax and yy==ay) and free(xx,yy,g) then
     seen[k]=true;q[#q+1]={x=xx,y=yy}
     if #q>8 then return true end
    end
   end
  end
  return false
 end
 for _,g in ipairs(order) do
  local ps=groups[g]
  -- Isolated underground mouths protect adjacent ports carrying different fluids.
  -- Establish that escape before choosing a common network anchor.
  for _,p in ipairs(ps) do
    local v=vectors[p.dir];local dx,dy=v[1],v[2]
    if not p.external and not occupied[key(p.x,p.y)] and not network[key(p.x,p.y)] and (not free(p.x,p.y,g) or not open_landing(p.x,p.y,nil,nil,nil,nil,g)) then
      for length=2,maxdist do
        local bx,by=p.x+dx*length,p.y+dy*length
        local lx,ly=bx+dx,by+dy
        local next_key=key(lx+dx,ly+dy)
        -- A later port escape must not replace this port's surface landing
        -- with another underground mouth, even when both carry the same fluid.
        -- The surface landing may turn; open_landing rejects sealed pockets.
        -- Requiring another straight cell rejects valid adjacent chemical inputs.
        if not reserved[key(bx,by)] and not reserved[key(lx,ly)] and not reserved[next_key]
          and free(bx,by,g,p.dir) and free(lx,ly,g) and tunnel_ok(p.x,p.y,bx,by,g) and open_landing(lx,ly,bx,by,p.x,p.y,g) then
          add(p.x,p.y,g,(p.dir+8)%16);add(bx,by,g,p.dir)
          tunnels[#tunnels+1]={x=p.x,y=p.y,xx=bx,yy=by}
          p.x=lx;p.y=ly;reserved[key(lx,ly)]=g;reserved[next_key]=g;required_surface[key(lx,ly)]=true
          break
        end
      end
    end
  end
 end
 for _,g in ipairs(order) do
  local ps=groups[g];local targets={}
  for i,p in ipairs(ps) do
   if not free(p.x,p.y,g) then failures=failures+1;report('[BFH-fluid] FAIL occupied port '..p.fluid..' at '..key(p.x,p.y))
   elseif next(targets)==nil then add(p.x,p.y,g);targets[key(p.x,p.y)]=true
   else
    local path=search(p,targets)
    if not path then report('[BFH-fluid] Deferred connection '..p.fluid..' at '..key(p.x,p.y));add(p.x,p.y,g)
    else
     -- Commit from the existing network to the new port.
     local start_ug=false
     for _,a in ipairs(path) do
      add(a.x,a.y,g);targets[key(a.x,a.y)]=true
      if a.ax then
       if a.ax==p.x and a.ay==p.y then start_ug=true end
       add(a.ax,a.ay,g,(a.dir+8)%16);add(a.bx,a.by,g,a.dir)
       tunnels[#tunnels+1]={x=a.ax,y=a.ay,xx=a.bx,yy=a.by}
      end
      local fx,fy=a.from:match('^(-?%d+),(-?%d+)$');fx=tonumber(fx);fy=tonumber(fy)
      if fx~=p.x or fy~=p.y then add(fx,fy,g);targets[key(fx,fy)]=true end
     end
     if not start_ug then add(p.x,p.y,g);targets[key(p.x,p.y)]=true end
    end
   end
  end
 end
 -- Validate real surface openings and nearest facing underground mouths.
 -- Logical search nodes are not proof that the resulting pipe network is joined.
 local function components(g)
  local groups,seen={},{}
  local keys={};for k,n in pairs(network) do if n.group==g then keys[#keys+1]=k end end;table.sort(keys)
  local function connects(a,d)return a.dir==nil or a.dir==d end
  for _,start in ipairs(keys) do if not seen[start] then
   local group={};groups[#groups+1]=group;local q={start};seen[start]=true;local head=1
   while q[head] do
    local k=q[head];head=head+1;group[#group+1]=k
    local sx,sy=k:match('^(-?%d+),(-?%d+)$');local x,y=tonumber(sx),tonumber(sy);local n=network[k]
    local function visit(xx,yy)
     local kk=key(xx,yy);if network[kk] and network[kk].group==g and not seen[kk] then seen[kk]=true;q[#q+1]=kk end
    end
    for _,d in ipairs(dirs) do local v=vectors[d];local xx,yy=x+v[1],y+v[2];local other=network[key(xx,yy)]
     if other and other.group==g and connects(n,d) and connects(other,(d+8)%16) then visit(xx,yy) end
    end
    if n.dir~=nil then
     local v=vectors[(n.dir+8)%16]
     for distance=1,maxdist do
      local xx,yy=x+v[1]*distance,y+v[2]*distance;local other=network[key(xx,yy)]
      if other and other.dir==(n.dir+8)%16 then visit(xx,yy);break end
     end
    end
   end
  end end
  return groups
 end
 for _,g in ipairs(order) do
  local parts=components(g)
  for attempt=1,3 do
   if #parts<=1 then break end
   local targets={}
   for i=2,#parts do for _,k in ipairs(parts[i]) do if network[k].dir==nil then targets[k]=true end end end
   local repaired=false
   for _,k in ipairs(parts[1]) do if network[k].dir==nil and next(targets) then
    local x,y=k:match('^(-?%d+),(-?%d+)$');local p={x=tonumber(x),y=tonumber(y),group=g}
    local path=search(p,targets)
    if path then
     for _,edge in ipairs(path) do
      add(edge.x,edge.y,g)
      if edge.ax then
       add(edge.ax,edge.ay,g,(edge.dir+8)%16);add(edge.bx,edge.by,g,edge.dir)
       tunnels[#tunnels+1]={x=edge.ax,y=edge.ay,xx=edge.bx,yy=edge.by}
      end
      local fx,fy=edge.from:match('^(-?%d+),(-?%d+)$');add(tonumber(fx),tonumber(fy),g)
     end
     repaired=true;break
    end
   end end
   local updated=components(g)
   if not repaired or #updated>=#parts then parts=updated;break end
   parts=updated
  end
  if #parts>1 then failures=failures+#parts-1;report('[BFH-fluid] FAIL fragmented network '..g..': '..#parts..' components') end
 end
 report('[BFH-fluid] Ports='..#ports..'; failures='..failures)
 return en,failures
end
-- Finish independent banks before packing them: neighbouring banks must not
-- consume one another's fluid escape corridors. No inter-bank pipe is added.
function M.independent(entities,blocks,id,settings,report,row_gap)
 local result={};local row,ox,oy,height=nil,0,0,0;local failures=0
 for i,b in ipairs(blocks)do
  local built=work.cached('independent-bank-'..i,function()
   local es={};for j=b.entity_first,b.entity_last do es[#es+1]=entities[j]end
   local source=work.fork('independent-bank-source',{entities=es,block=b})
   es=source.entities;local meta=source.block;meta.entity_first=1;meta.entity_last=#es
   local ports,issues=M.ports(es,{meta})
   for _,issue in ipairs(issues)do report(issue)end
   local next_id,missing=M.route(es,ports,id,settings,report)
   return {entities=es,block=meta,id=next_id,failures=missing+#issues}
  end,true)
  local placed=work.fork('independent-bank-placement-'..i,built)
  id=placed.id;failures=failures+placed.failures
  local meta=placed.block
  local left,top=meta.offset_x or 0,meta.offset_y or 0
  local right,bottom=left+(meta.width or 0),top+(meta.height or 0)
  for _,e in ipairs(placed.entities)do local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
   if (e.direction or 0)%8==4 then w,h=h,w end
   left=math.min(left,e.position.x-w/2);top=math.min(top,e.position.y-h/2)
   right=math.max(right,e.position.x+w/2);bottom=math.max(bottom,e.position.y+h/2)
  end
  local original_row=b.offset_y or 0
  if row~=original_row then
   if row~=nil then oy=oy+height+(row_gap or 0)end
   row=original_row;ox=0;height=0
  end
  local dx,dy=ox-left,oy-top
  local first=#result+1
  for _,e in ipairs(placed.entities)do
   e.position.x=e.position.x+dx;e.position.y=e.position.y+dy;result[#result+1]=e
  end
  boundaries.translate(meta,dx,dy)
  meta.entity_first=first;meta.entity_last=#result;blocks[i]=meta
  ox=ox+(right-left)+1;height=math.max(height,bottom-top)
 end
 return id,failures,result
end
return M
