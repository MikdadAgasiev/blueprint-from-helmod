-- Place researched poles in free cells, then explicitly wire a single network.
local M={}
local work=require('generation_work')
local equipment=require('equipment')
local function key(x,y)return x..','..y end
function M.catalog(force,items)
 local result={}
 for _,name in ipairs(equipment.entities(force,'electric-pole',items)) do
  local p=prototypes.entity[name];local radius=p.get_supply_area_distance('normal') or 0;local wire=p.get_max_wire_distance('normal') or 0
  if radius>0 and wire>=1 and p.tile_width<=4 and p.tile_height<=4 then result[#result+1]={name=name,w=p.tile_width,h=p.tile_height,radius=radius,wire=wire} end
 end
 table.sort(result,function(a,b)if a.w*a.h~=b.w*b.h then return a.w*a.h<b.w*b.h end;if a.radius~=b.radius then return a.radius>b.radius end;return a.name<b.name end)
 return result
end
local function step(a,s)
 local p=a.pole
 local function free(x,y)
  for xx=x,x+p.w-1 do for yy=y,y+p.h-1 do if s.occupied[key(xx,yy)] or s.reserved[key(xx,yy)] then return false end end end
  return true
 end
 local function add(x,y)
  local e={name=p.name,entity_number=s.next_id,position={x=x+p.w/2,y=y+p.h/2}}
  s.next_id=s.next_id+1;s.poles[#s.poles+1]=e
  for xx=x,x+p.w-1 do for yy=y,y+p.h-1 do s.occupied[key(xx,yy)]=true end end
  return #s.poles
 end
 local function edge(i,j)
  s.edges[#s.edges+1]={i,j};s.degree[i]=(s.degree[i] or 0)+1;s.degree[j]=(s.degree[j] or 0)+1
 end
 local function distance(i,j)local x,y=s.poles[i].position,s.poles[j].position;return (x.x-y.x)^2+(x.y-y.y)^2 end
 if not s.phase then
  s.occupied={};s.reserved={};s.demands={};s.poles={};s.edges={};s.degree={};s.covered={};s.next_id=1;s.entity_index=1
  s.left,s.top,s.right,s.bottom=math.huge,math.huge,-math.huge,-math.huge;s.phase='geometry'
  for _,port in ipairs(a.access) do
   local direction=port.direction or 4;local dx,dy=direction==4 and 1 or direction==12 and -1 or 0,direction==8 and 1 or direction==0 and -1 or 0
   local sign=port.output and 1 or -1
   for n=0,3 do s.reserved[key(port.x+dx*n*sign,port.y+dy*n*sign)]=true end
  end
 end
 if s.phase=='geometry' then
  while s.entity_index<=#a.entities do
   if not work.consume(16) then return false end
   local e=a.entities[s.entity_index];s.entity_index=s.entity_index+1;s.next_id=math.max(s.next_id,(e.entity_number or 0)+1)
   local proto=prototypes.entity[e.name];local w,h=proto.tile_width,proto.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end
   local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
   for xx=x,x+w-1 do for yy=y,y+h-1 do s.occupied[key(xx,yy)]=true end end
   s.left=math.min(s.left,x);s.right=math.max(s.right,x+w-1);s.top=math.min(s.top,y);s.bottom=math.max(s.bottom,y+h-1)
   local energy=proto.electric_energy_source_prototype
   if energy and proto.type~='electric-pole' and energy.usage_priority~='primary-output' and energy.usage_priority~='secondary-output' then
    s.demands[#s.demands+1]={left=e.position.x-w/2,right=e.position.x+w/2,top=e.position.y-h/2,bottom=e.position.y+h/2,id=e.entity_number,name=e.name}
   end
  end
  if #s.demands==0 then return true,{}, {pole=p.name,targets=0,uncovered=0,components=0} end
  s.xmin=s.left-2;s.xmax=s.right+2-p.w+1;s.ymin=s.top-2;s.ymax=s.bottom+2-p.h+1
  s.x=s.xmin;s.y=s.ymin;s.candidates={};s.phase='candidates'
 end
 local function candidate_before(a,b)
  if a.count~=b.count then return a.count>b.count end
  if a.near~=b.near then return a.near<b.near end
  if a.x~=b.x then return a.x<b.x end
  return a.y<b.y
 end
 local function candidate_push(c)
  local heap=s.candidates;heap[#heap+1]=c;local i=#heap
  while i>1 do local parent=math.floor(i/2);if candidate_before(heap[parent],c) then break end;heap[i]=heap[parent];i=parent end;heap[i]=c
 end
 local function candidate_pop()
  local heap=s.candidates;local c=heap[1];local tail=table.remove(heap)
  if #heap>0 then local i=1;while i*2<=#heap do local j=i*2;if j<#heap and candidate_before(heap[j+1],heap[j]) then j=j+1 end;if candidate_before(tail,heap[j]) then break end;heap[i]=heap[j];i=j end;heap[i]=tail end
  return c
 end
 if s.phase=='candidates' then
  while s.x<=s.xmax do
   if not work.consume(16) then return false end
   local x,y=s.x,s.y;s.y=s.y+1;if s.y>s.ymax then s.y=s.ymin;s.x=s.x+1 end
   if free(x,y) then
    local cx,cy=x+p.w/2,y+p.h/2;local cover={}
    for i,d in ipairs(s.demands) do if d.left<cx+p.radius-1e-7 and d.right>cx-p.radius+1e-7 and d.top<cy+p.radius-1e-7 and d.bottom>cy-p.radius+1e-7 then cover[#cover+1]=i end end
    if #cover>0 then candidate_push{x=x,y=y,cover=cover,count=#cover,near=(x-(s.left+s.right)/2)^2+(y-(s.top+s.bottom)/2)^2} end
   end
  end
  s.phase='choose';s.remaining=#s.demands
 end
 if s.phase=='choose' then
  while #s.candidates>0 and s.remaining>0 do
   if not work.consume(16) then return false end
   local c=candidate_pop()
   if free(c.x,c.y) then
    local count=0;for _,i in ipairs(c.cover) do if not s.covered[i] then count=count+1 end end
    if count>0 then
     if count<c.count then c.count=count;candidate_push(c)
     else
      add(c.x,c.y)
      for _,i in ipairs(c.cover) do if not s.covered[i] then s.covered[i]=true;s.remaining=s.remaining-1 end end
     end
    end
   end
  end
  s.candidates=nil;s.phase='network'
 end
 local function push(heap,n)
  heap[#heap+1]=n;local i=#heap
  while i>1 do local parent=math.floor(i/2);if heap[parent].priority<=n.priority then break end;heap[i]=heap[parent];i=parent end;heap[i]=n
 end
 local function pop(heap)
  local n=heap[1];local tail=table.remove(heap)
  if #heap>0 then local i=1;while i*2<=#heap do local j=i*2;if j<#heap and heap[j+1].priority<heap[j].priority then j=j+1 end;if tail.priority<=heap[j].priority then break end;heap[i]=heap[j];i=j end;heap[i]=tail end
  return n
 end
 while s.phase=='network' or s.phase=='bridge' do
  if s.phase=='network' then
   if not work.consume(32) then return false end
   local parents={};for i=1,#s.poles do parents[i]=i end
   local function root(i)while parents[i]~=i do i=parents[i] end;return i end
   for _,e in ipairs(s.edges) do parents[root(e[1])]=root(e[2]) end
   local components={};for i=1,#s.poles do components[root(i)]=true end;s.components=0;for _ in pairs(components) do s.components=s.components+1 end
   if s.components<=1 then s.phase='done';break end
   local best,dist
   for i=1,#s.poles do for j=i+1,#s.poles do if root(i)~=root(j) and (s.degree[i] or 0)<5 and (s.degree[j] or 0)<5 then
    local d=distance(i,j);if not dist or d<dist then best={i,j};dist=d end
   end end end
   if not best then s.phase='done';break end
   if dist<=p.wire^2+1e-7 then edge(best[1],best[2])
   else
    local e=s.poles[best[1]];local target=s.poles[best[2]];local x,y=e.position.x-p.w/2,e.position.y-p.h/2
    s.bridge={from=best[1],to=best[2],tx=target.position.x-p.w/2,ty=target.position.y-p.h/2,heap={},cost={[key(x,y)]=0},parents={},visits=0}
    push(s.bridge.heap,{x=x,y=y,cost=0,priority=0});s.phase='bridge'
   end
  else
   local b=s.bridge
   while #b.heap>0 and b.visits<30000 do
    if not work.consume(32) then return false end
    local n=pop(b.heap);local nk=key(n.x,n.y)
    if n.cost==b.cost[nk] then
     b.visits=b.visits+1
     if (n.x-b.tx)^2+(n.y-b.ty)^2<=p.wire^2+1e-7 then
      local reversed={};while b.parents[nk] do reversed[#reversed+1]=n;n=b.parents[nk];nk=key(n.x,n.y) end
      local previous=b.from
      for i=#reversed,1,-1 do local v=reversed[i];local id=add(v.x,v.y);edge(previous,id);previous=id end
      edge(previous,b.to);s.bridge=nil;s.phase='network';break
     end
     local function offer(x,y)
      local dx,dy=x-n.x,y-n.y;if dx==0 and dy==0 or dx*dx+dy*dy>p.wire^2+1e-7 then return end
      local pad=math.ceil(math.min(p.wire,32));if x<s.xmin-pad or x>s.xmax+pad or y<s.ymin-pad or y>s.ymax+pad or not free(x,y) then return end
      -- Existing poles are in occupied; future bridge poles are only in
      -- this path. Reject overlap with those ancestors before committing it.
      local previous=n
      while previous do
       if math.abs(x-previous.x)<p.w and math.abs(y-previous.y)<p.h then return end
       previous=b.parents[key(previous.x,previous.y)]
      end
      local k=key(x,y);local cost=n.cost+1
      if not b.cost[k] or cost<b.cost[k] then b.cost[k]=cost;b.parents[k]=n;push(b.heap,{x=x,y=y,cost=cost,priority=cost+math.sqrt((x-b.tx)^2+(y-b.ty)^2)/p.wire}) end
     end
     local dx,dy=b.tx-n.x,b.ty-n.y;local length=math.sqrt(dx*dx+dy*dy);local stride=math.max(1,math.floor(p.wire)-1)
     offer(n.x+math.floor(dx/length*stride+.5),n.y+math.floor(dy/length*stride+.5))
     for _,length in ipairs({1,math.max(1,math.floor(stride/2)),stride}) do for xx=-1,1 do for yy=-1,1 do offer(n.x+xx*length,n.y+yy*length) end end end
    end
   end
   if s.phase=='bridge' then s.phase='done';s.failed_bridge=true end
  end
 end
 if s.phase=='done' then
  local copper=defines.wire_connector_id.pole_copper
  for _,e in ipairs(s.edges) do local source,target=s.poles[e[1]],s.poles[e[2]];source.wires=source.wires or {};source.wires[#source.wires+1]={source.entity_number,copper,target.entity_number,copper} end
  local missing={};for i,d in ipairs(s.demands) do if not s.covered[i] then missing[#missing+1]={entity=d.id,name=d.name} end end
  return true,s.poles,{pole=p.name,targets=#s.demands,uncovered=#missing,missing=missing,components=s.components or 0,bridges_failed=s.failed_bridge or false}
 end
end
work.register('power-plan',step)
function M.plan(entities,force,settings,inputs,outputs,items)
 if settings.use_power==false then return {},{disabled=true,targets=0,uncovered=0,components=0} end
 local available=work.cached('power-catalog',function()return M.catalog(force,items)end,true);local pole=available[1]
 if settings.pole_name and settings.pole_name~='auto' then for _,p in ipairs(available) do if p.name==settings.pole_name then pole=p end end end
 if not pole then return {},{unavailable=true,uncovered=0,components=0} end
 local access={}
 for _,p in ipairs(inputs or {}) do access[#access+1]={x=p.x,y=p.y,direction=p.direction or 4} end
 for _,p in ipairs(outputs or {}) do access[#access+1]={x=p.x,y=p.y,direction=p.direction or 4,output=true} end
 return work.operation('power-plan',nil,{entities=entities,pole=pole,access=access})
end
return M
