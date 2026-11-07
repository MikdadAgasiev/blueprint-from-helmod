-- Fluid routing uses prototype connection positions and directions, never template sides.
local M={}
local work=require("generation_work")
local pipe_pair=require("pipe_pair")
local capacity=require('capacity')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local dirs={0,4,8,12}
local function key(x,y)return x..','..y end
function M.ports(entities,blocks)
 local ports,issues={},{}
 local by_id={};for _,e in ipairs(entities) do if e.entity_number then by_id[e.entity_number]=e end end
 for bi,b in ipairs(blocks) do
  local machines={}
  if b.machine_ids then for _,id in ipairs(b.machine_ids) do if by_id[id] then machines[#machines+1]=by_id[id] end end
  else for ei=b.entity_first,b.entity_last do if entities[ei] then machines[#machines+1]=entities[ei] end end end
  local machine_counts={};for _,e in ipairs(machines) do if e.recipe then machine_counts[e.recipe]=(machine_counts[e.recipe] or 0)+1 end end
  for _,e in ipairs(machines) do
   local ep=prototypes.entity[e.name]
   if e.recipe and ep.fluidbox_prototypes then
    local recipe=prototypes.recipe[e.recipe]
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
          if node then for _,flow in pairs(node[side] or {}) do if flow.type=='fluid' and flow.name==item.name and (type(flow.count)=='number' or type(flow.amount)=='number') then rate=capacity.flow(flow,node)/(machine_counts[e.recipe] or 1);break end end end
          ports[#ports+1]={x=math.floor(e.position.x+pos.x+v[1]),y=math.floor(e.position.y+pos.y+v[2]),dir=dir,categories=c.connection_category,fluid=item.name,kind=kind,rate=rate,box=chosen.index,machine=e.entity_number,block=bi}
          break
         end
        end
       end
       if connected then break end
      end
      if not connected then issues[#issues+1]="[BFH-fluid] FAIL no compatible port: "..e.name.."/"..e.recipe.."/"..item.name end
     end
    end
   end
  end
 end
 return ports,issues
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
 local function free(x,y,g)
  if args.output_face_x and x>args.output_face_x then return false end
  if face_x and x<face_x+2 and external_access[key(x,y)]~=g then return false end
  local k=key(x,y)
  if (network[k] and network[k].dir~=nil) or occupied[k] or (reserved[k] and reserved[k]~=g) or (network[k] and network[k].group~=g) then return false end
  for _,d in ipairs(dirs) do local v=vectors[d];local q=key(x+v[1],y+v[2]);if (reserved[q] and reserved[q]~=g) or (network[q] and network[q].group~=g) then return false end end
  return true
 end
 local function tunnel_ok(x,y,xx,yy)
  for _,t in ipairs(tunnels) do
   if x==xx and t.x==t.xx and x==t.x and math.max(math.min(y,yy),math.min(t.y,t.yy))<=math.min(math.max(y,yy),math.max(t.y,t.yy)) then return false end
   if y==yy and t.y==t.yy and y==t.y and math.max(math.min(x,xx),math.min(t.x,t.xx))<=math.min(math.max(x,xx),math.max(t.x,t.xx)) then return false end
  end
  return true
 end
  local g=p.group;local heap=saved.heap or {};local dist,parent=saved.dist or {},saved.parent or {}
  local availability=saved.availability or {}
  local function available(x,y)
    local k=key(x,y);if availability[k]==nil then availability[k]=free(x,y,g) end
    return availability[k]
  end
  local goal_cells=saved.goal_cells
  if not goal_cells then
   goal_cells={};saved.goal_cells=goal_cells
   for k in pairs(targets) do local x,y=k:match('^(-?%d+),(-?%d+)$');goal_cells[#goal_cells+1]={tonumber(x),tonumber(y)} end
  end
  local function heuristic(x,y)
   local best=math.huge
   for _,q in ipairs(goal_cells) do best=math.min(best,math.abs(x-q[1])+math.abs(y-q[2])) end
   return best*0.4
  end
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
   if not work.consume(16) then saved.visits=visits;return false end
   local n=pop();local k=key(n.x,n.y)
   if n.cost==dist[k] then
    if not work.route_visit() then return true end
    visits=visits+1;if visits>100000 then return true end
    if targets[k] then
     local path={};while k~=sk do local a=parent[k];path[#path+1]=a;k=a.from end
     return true,path
    end
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
     local cursor=k
     while cursor~=sk do
      local old=parent[cursor]
      if old.ax then
       if edge.ax then
        if edge.ax==edge.bx and old.ax==old.bx and edge.ax==old.ax
            and math.max(math.min(edge.ay,edge.by),math.min(old.ay,old.by))<=math.min(math.max(edge.ay,edge.by),math.max(old.ay,old.by)) then return end
        if edge.ay==edge.by and old.ay==old.by and edge.ay==old.ay
            and math.max(math.min(edge.ax,edge.bx),math.min(old.ax,old.bx))<=math.min(math.max(edge.ax,edge.bx),math.max(old.ax,old.bx)) then return end
       end
       if (x==old.ax and y==old.ay) or (x==old.bx and y==old.by) then return end
       if edge.ax and ((edge.ax==old.ax and edge.ay==old.ay) or (edge.ax==old.bx and edge.ay==old.by)
           or (edge.bx==old.ax and edge.by==old.ay) or (edge.bx==old.bx and edge.by==old.by)) then return end
      end
      if edge.ax and ((edge.ax==old.x and edge.ay==old.y) or (edge.bx==old.x and edge.by==old.y)) then return end
      cursor=old.from
     end
     if not dist[q] or nc<dist[q] then dist[q]=nc;edge.from=k;edge.x=x;edge.y=y;parent[q]=edge;push{x=x,y=y,cost=nc} end
    end
    for _,d in ipairs(dirs) do
     local v=vectors[d];local dx,dy=v[1],v[2]
     offer(n.x+dx,n.y+dy,1,{})
     local start=(k==sk and d==p.dir) and 0 or 1
     local ax,ay=n.x+dx*start,n.y+dy*start
     if not network[key(ax,ay)] and available(ax,ay) then
      for length=2,maxdist do
       local bx,by=ax+dx*length,ay+dy*length
       if not network[key(bx,by)] and available(bx,by) and tunnel_ok(ax,ay,bx,by) then
        offer(bx+dx,by+dy,3+length*0.15,{ax=ax,ay=ay,bx=bx,by=by,dir=d})
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
 local groups,order={},{}
 local external_access={}
 for _,p in ipairs(ports) do
  p.group=p.fluid..(settings.link_mode=='independent' and ('/'..p.block) or '')
  reserved[key(p.x,p.y)]=p.group
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
 table.sort(order)
 local failures=0
 local pipe=settings.pipe or 'pipe'
 local ug,maxdist,reason=pipe_pair.resolve(pipe)
 if not ug and #ports>0 then report('[BFH-fluid] Surface-only routing: '..pipe..'; '..reason) end
 local function free(x,y,g)
  if settings.output_face_x and x>settings.output_face_x then return false end
  if settings.external_face_x and x<settings.external_face_x+2 and external_access[key(x,y)]~=g then return false end
  local k=key(x,y)
  if (network[k] and network[k].dir~=nil) or occupied[k] or (reserved[k] and reserved[k]~=g) or (network[k] and network[k].group~=g) then return false end
  for _,d in ipairs(dirs) do local v=vectors[d];local q=key(x+v[1],y+v[2]);if (reserved[q] and reserved[q]~=g) or (network[q] and network[q].group~=g) then return false end end
  return true
 end
 local function tunnel_ok(x,y,xx,yy)
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
    network=network,reserved=reserved,tunnels=tunnels,external_access=external_access,
    face_x=settings.external_face_x,output_face_x=settings.output_face_x,xmin=xmin,xmax=xmax,ymin=ymin,ymax=ymax,maxdist=maxdist})
 end
 for _,g in ipairs(order) do
  local ps=groups[g];local targets={}
  -- Isolated underground mouths protect adjacent ports carrying different fluids.
  -- Establish that escape before choosing a common network anchor.
  for _,p in ipairs(ps) do
    local v=vectors[p.dir];local dx,dy=v[1],v[2]
    if not p.external and not occupied[key(p.x,p.y)] and not network[key(p.x,p.y)] then
      for length=2,maxdist do
        local bx,by=p.x+dx*length,p.y+dy*length
        if free(bx,by,g) and free(bx+dx,by+dy,g) and tunnel_ok(p.x,p.y,bx,by) then
          add(p.x,p.y,g,(p.dir+8)%16);add(bx,by,g,p.dir)
          tunnels[#tunnels+1]={x=p.x,y=p.y,xx=bx,yy=by}
          p.x=bx+dx;p.y=by+dy
          break
        end
      end
    end
  end
  for i,p in ipairs(ps) do
   if not free(p.x,p.y,g) then failures=failures+1;report('[BFH-fluid] FAIL occupied port '..p.fluid..' at '..key(p.x,p.y))
   elseif next(targets)==nil then add(p.x,p.y,g);targets[key(p.x,p.y)]=true
   else
    local path=search(p,targets)
    if not path then failures=failures+1;report('[BFH-fluid] FAIL no route '..p.fluid..' at '..key(p.x,p.y));add(p.x,p.y,g)
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
return M
