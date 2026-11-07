-- Separate fluidboxes; directed openings handle pumps whose production_type is none.
local M={}
local work=require('generation_work')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local transports={pipe=true,['pipe-to-ground']=true,['storage-tank']=true,pump=true}
local function key(x,y)return x..','..y end
local function compatible(a,b)
 for _,x in ipairs(a or {'default'}) do for _,y in ipairs(b or {'default'}) do if x==y then return true end end end
 return false
end
local function permits(flow,kind)return not flow or flow=='input-output' or flow==kind end
local function step(args,s)
 if not s.phase then
  s.phase='nodes';s.index=1;s.nodes={};s.openings={};s.normal={};s.underground={};s.parents={};s.edges={};s.issues={};s.occupied={}
 end
 local function issue(text)s.issues[#s.issues+1]=text end
 local function root(k)
  local r=k;while s.parents[r]~=r do r=s.parents[r] end
  while s.parents[k]~=k do local p=s.parents[k];s.parents[k]=r;k=p end
  return r
 end
 local function connect(a,b)
  if a.node==b.node then return end
  local x,y=root(a.node),root(b.node);if x~=y then s.parents[y]=x end
  if permits(a.flow,'output') and permits(b.flow,'input') then s.edges[a.node][b.node]=true end
  if permits(b.flow,'output') and permits(a.flow,'input') then s.edges[b.node][a.node]=true end
 end
 if s.phase=='nodes' then
  while s.index<=#args.entities do
   if not work.consume(8) then return false end
   local e=args.entities[s.index];s.index=s.index+1;local p=prototypes.entity[e.name]
   if p and transports[p.type] then
    local rotation=e.direction or 0
    local w,h=p.tile_width,p.tile_height;if rotation==4 or rotation==12 then w,h=h,w end
    local left,top=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
    for x=left,left+w-1 do for y=top,top+h-1 do local k=key(x,y)
     if s.occupied[k] then issue('Overlapping fluid entities at '..k) end;s.occupied[k]=true
    end end
    for _,fb in pairs(p.fluidbox_prototypes or {}) do
     local node=#s.nodes+1;s.nodes[node]={filter=fb.filter and fb.filter.name,name=e.name};s.parents[node]=node;s.edges[node]={}
     for _,c in ipairs(fb.pipe_connections) do
      local pos=c.positions and c.positions[rotation/4+1];local d=c.direction and (c.direction+rotation)%16
      local v=d and vectors[d]
      if not v or not pos or (c.connection_type~='normal' and c.connection_type~='underground') then
       issue('Unsupported fluid opening: '..e.name)
      else
       local x,y=math.floor(e.position.x+pos.x),math.floor(e.position.y+pos.y)
       local opening={node=node,x=x,y=y,dir=d,flow=c.flow_direction,categories=c.connection_category or {'default'},kind=c.connection_type,distance=c.max_underground_distance or 0}
       local index=c.connection_type=='normal' and s.normal or s.underground;local k=key(x,y)..'/'..d
       index[k]=index[k] or {};index[k][#index[k]+1]=opening;s.openings[#s.openings+1]=opening
       if c.flow_direction and c.flow_direction~='input-output' then s.directed=true end
       if p.type~='pump' and not permits(c.flow_direction,'input-output') then issue('Unsupported one-way pipe opening: '..e.name) end
      end
     end
    end
   end
  end
  s.phase='edges';s.index=1
 end
 if s.phase=='edges' then
  while s.index<=#s.openings do
   if not work.consume(4) then return false end
   local a=s.openings[s.index];s.index=s.index+1;local v=vectors[a.dir];local reverse=(a.dir+8)%16
   if a.kind=='normal' then
    for _,b in ipairs(s.normal[key(a.x+v[1],a.y+v[2])..'/'..reverse] or {}) do
     if compatible(a.categories,b.categories) then connect(a,b) end
    end
   else
    for distance=1,a.distance do
     local matched=false
     for _,b in ipairs(s.underground[key(a.x+v[1]*distance,a.y+v[2]*distance)..'/'..reverse] or {}) do
      if distance<=b.distance and compatible(a.categories,b.categories) then connect(a,b);matched=true end
     end
     if matched then break end
    end
   end
  end
  s.phase='filters';s.index=1;s.filters={}
 end
 if s.phase=='filters' then
  while s.index<=#s.nodes do
   if not work.consume(8) then return false end
   local i=s.index;s.index=i+1;local n=s.nodes[i]
   if n.filter then local r=root(i);s.filters[r]=s.filters[r] or {};s.filters[r][n.filter]=true end
  end
  s.phase='ports';s.index=1;s.resources={};s.groups={};s.group_order={}
 end
 if s.phase=='ports' then
  while s.index<=#args.ports do
   if not work.consume(8) then return false end
   local p=args.ports[s.index];s.index=s.index+1;local k=key(p.x,p.y);local matches={}
   for _,a in ipairs(s.normal[k..'/'..((p.dir+8)%16)] or {}) do
    if compatible(p.categories,a.categories) then matches[#matches+1]=a end
   end
   if #matches==0 then issue('Disconnected fluid port: '..p.fluid..' at '..k)
   else
    local g=p.fluid..(args.independent and '/'..tostring(p.block or 0) or '')
    local group=s.groups[g]
    if not group then group={sources={},sinks={},fluid=p.fluid};s.groups[g]=group;s.group_order[#s.group_order+1]=g end
    for _,a in ipairs(matches) do
     local r=root(a.node)
     for filter in pairs(s.filters[r] or {}) do if filter~=p.fluid then issue('Incompatible pipe filter: '..filter..' / '..p.fluid..' at '..k) end end
     if s.resources[r] and s.resources[r]~=p.fluid then issue('Mixed fluids: '..s.resources[r]..' / '..p.fluid..' at '..k) end
     s.resources[r]=p.fluid
     if group.root and group.root~=r then issue('Disconnected fluid network: '..g..' at '..k) end;group.root=r
     if p.kind=='output' then
      if permits(a.flow,'input') then group.sources[a.node]=true else issue('Wrong fluid flow direction: '..p.fluid..' at '..k) end
     elseif p.kind=='input' then
      group.sinks[#group.sinks+1]={node=a.node,x=p.x,y=p.y,can_exit=permits(a.flow,'output')}
     end
    end
   end
  end
  if not s.directed then return true,s.issues end
  s.phase='reach';s.index=1
 end
 while s.index<=#s.group_order do
  local g=s.groups[s.group_order[s.index]]
  if not s.queue then
   s.queue={};s.seen={};s.head=1
   local sources={};for node in pairs(g.sources) do sources[#sources+1]=node end;table.sort(sources)
   for _,node in ipairs(sources) do s.queue[#s.queue+1]=node;s.seen[node]=true end
  end
  while s.queue[s.head] do
   if not work.consume(8) then return false end
   local node=s.queue[s.head];s.head=s.head+1
   local neighbours={};for other in pairs(s.edges[node]) do neighbours[#neighbours+1]=other end;table.sort(neighbours)
   for _,other in ipairs(neighbours) do if not s.seen[other] then s.seen[other]=true;s.queue[#s.queue+1]=other end end
  end
  if not work.consume(8) then return false end
  -- Unknown external sources are not invented inside a directional device.
  for _,sink in ipairs(g.sinks) do
   if not sink.can_exit or (next(g.sources) and not s.seen[sink.node]) then issue('Unreachable fluid consumer: '..g.fluid..' at '..key(sink.x,sink.y)) end
  end
  s.index=s.index+1;s.queue=nil;s.seen=nil
 end
 return true,s.issues
end
work.register('validate-fluid-graph',step)
-- Allows another resumable operation to run this check without nesting saved stacks.
M.step=step
function M.check(entities,ports,independent)
 return work.operation('validate-fluid-graph',nil,{entities=entities,ports=ports,independent=independent})
end
return M
