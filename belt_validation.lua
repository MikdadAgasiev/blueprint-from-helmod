local resources=require('resources')
-- Checks planned block inputs and individual machine pickup points; belt lanes are not modelled.
local M={}
local work=require('generation_work')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
local function rotated(p,d)
 local x,y=p.x or p[1],p.y or p[2]
 for i=1,(d or 0)/4 do x,y=-y,x end
 return x,y
end
-- A splitter edge can be reached from either half; retain both alternatives.
local function edge(n,id,c)
 n.edges[id]=true
 if n.filter then
  n.rules=n.rules or {};n.rules[id]=n.rules[id] or {}
  local first=n.cells[1];local last=n.cells[#n.cells]
  local left=(n.d==0 and c.x==first.x) or (n.d==4 and c.y==first.y) or (n.d==8 and c.x==last.x) or (n.d==12 and c.y==last.y)
  local selected=(n.priority=='left' and left) or (n.priority=='right' and not left)
  n.rules[id][selected and 'match' or 'other']=true
 end
end
local function passes(n,id,item)
 if not n.filter or not n.rules or not n.rules[id] then return true end
 local f=n.filter;if type(f)=='string' then f={name=f,quality='normal'} end
 local q=resources.grade(item);local level=(prototypes.quality[q] or {}).level or 0
 local wanted_name=resources.quality(f.quality)
 local wanted=(prototypes.quality[wanted_name] or {}).level or 0
 local cmp=f.comparator or '='
 local quality=(cmp=='=' and q==wanted_name) or (cmp=='>' and level>wanted) or (cmp=='<' and level<wanted) or (cmp=='>=' and level>=wanted) or (cmp=='<=' and level<=wanted) or (cmp=='≠' and q~=wanted_name)
 local matches=(not f.name or f.name==resources.name(item)) and quality
 return n.rules[id][matches and 'match' or 'other'] or false
end
local function step(a,s)
 s.nodes=s.nodes or {};s.cells=s.cells or {};s.index=s.index or 1;s.issues=s.issues or {};s.machines=s.machines or {};s.machine_cells=s.machine_cells or {};s.arms=s.arms or {}
 if not s.phase then
  while s.index<=#a.entities do
   if not work.consume(8) then return false end
   local entity_index=s.index;local e=a.entities[s.index];s.index=s.index+1;local p=prototypes.entity[e.name]
   local bi=a.members[a.by_id and e.entity_number or entity_index];local block=bi and a.blocks[bi]
   local recipe_name=e.recipe or (p and p.type=='furnace' and block and block.recipe_node and block.recipe_node.name)
   if p and recipe_name then
    local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end
    local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
    local m={recipe=recipe_name,name=e.name,x=x,y=y,block=a.members[a.by_id and e.entity_number or entity_index],feeds={},unloads={}}
    s.machines[#s.machines+1]=m
    for dx=0,w-1 do for dy=0,h-1 do s.machine_cells[key(x+dx,y+dy)]=#s.machines end end
   elseif p and p.type=='inserter' and p.inserter_pickup_position and p.inserter_drop_position then
    local ax,ay=rotated(p.inserter_pickup_position,e.direction);local bx,by=rotated(p.inserter_drop_position,e.direction)
    s.arms[#s.arms+1]={x=math.floor(e.position.x+ax),y=math.floor(e.position.y+ay),tx=math.floor(e.position.x+bx),ty=math.floor(e.position.y+by)}
   elseif p and p.type=='loader-1x1' then
    local v=vectors[e.direction or 0]
    if v then s.arms[#s.arms+1]={x=math.floor(e.position.x-v[1]),y=math.floor(e.position.y-v[2]),tx=math.floor(e.position.x+(e.type=='input' and v[1] or 0)),ty=math.floor(e.position.y+(e.type=='input' and v[2] or 0))} end
   end
   if p and (p.type=='transport-belt' or p.type=='underground-belt' or p.type=='splitter' or p.type=='loader-1x1' or p.type=='container') then
    local w,h=p.tile_width,p.tile_height;local d=e.direction or 0
    if d==4 or d==12 then w,h=h,w end
    local n={filter=p.type=='splitter' and e.filter,priority=e.output_priority,name=e.name,type=p.type,side=e.type,d=d,cells={},edges={},distance=p.max_underground_distance or 0}
    local id=#s.nodes+1;s.nodes[id]=n
    local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
    for dx=0,w-1 do for dy=0,h-1 do
     local k=key(x+dx,y+dy);s.cells[k]=id;n.cells[#n.cells+1]={x=x+dx,y=y+dy}
    end end
   end
  end
  s.phase='edges';s.index=1
 end
 if s.phase=='edges' then
  while s.index<=#s.nodes do
   if not work.consume(16) then return false end
   local id=s.index;s.index=s.index+1;local n=s.nodes[id];local v=vectors[n.d]
   if v then for _,c in ipairs(n.cells) do
    if n.type=='container' then
     for d,vec in pairs(vectors) do
      local other=s.cells[key(c.x+vec[1],c.y+vec[2])];local q=other and s.nodes[other]
      if q and q.type=='loader-1x1' and q.side=='output' and q.d==d then n.edges[other]=true end
     end
    elseif n.type=='underground-belt' and n.side~='output' then
     local found=false
     for distance=1,n.distance do
      local other=s.cells[key(c.x+v[1]*distance,c.y+v[2]*distance)];local q=other and s.nodes[other]
      if q and q.type=='underground-belt' and q.name==n.name and q.d%8==n.d%8 then
       found=true
       if q.d==n.d and q.side=='output' then n.edges[other]=true else s.issues[#s.issues+1]='Invalid underground belt at '..key(c.x,c.y) end
       break
      end
     end
     if not found then s.issues[#s.issues+1]='Unpaired underground belt at '..key(c.x,c.y) end
    else
     local other=s.cells[key(c.x+v[1],c.y+v[2])];local q=other and s.nodes[other]
     if q and other~=id and (q.type=='container' or q.d~=(n.d+8)%16) and not(q.type=='underground-belt' and q.side=='output')
      and (q.type~='splitter' or q.d==n.d)
      and (q.type~='loader-1x1' or (q.side=='input' and q.d==n.d))
      and (q.type~='container' or (n.type=='loader-1x1' and n.side=='input')) then edge(n,other,c) end
    end
   end end
  end
  s.phase='bindings';s.index=1
 end
 if s.phase=='bindings' then
  while s.index<=#s.arms do
   if not work.consume(8) then return false end
   local arm=s.arms[s.index];s.index=s.index+1;local id=s.machine_cells[key(arm.tx,arm.ty)]
   if id then s.machines[id].feeds[#s.machines[id].feeds+1]={x=arm.x,y=arm.y} end
   local source=s.machine_cells[key(arm.x,arm.y)]
   if source then s.machines[source].unloads[#s.machines[source].unloads+1]={x=arm.tx,y=arm.ty} end
  end
  s.phase='machines';s.index=1
 end
 if s.phase=='machines' then
  if a.skip_machines then s.index=#s.machines+1 end
  while s.index<=#s.machines do
   if not work.consume(8) then return false end
   local m=s.machines[s.index];s.index=s.index+1
   local b=m.block and a.blocks[m.block];local recipe=prototypes.recipe[m.recipe]
   for _,item in ipairs(((b or {}).recipe_node or recipe or {}).ingredients or {}) do if item.type~='fluid' then
    local sources={}
    for _,input in ipairs((b or {}).inputs or {}) do if input.ingredient==item.name then sources[#sources+1]=input end end
    a.demands[#a.demands+1]={x=m.x,y=m.y,name=item.name,sources=sources,targets=m.feeds,search_key=m.block and ('internal/'..m.block..'/'..item.name),machine_name=m.name,recipe=m.recipe,machine=m.name..'/'..m.recipe}
   end end
   if b and b.graph_bound and b.output_ports and #b.output_ports>0 then
    for _,item in ipairs((b.recipe_node or {}).products or {}) do if item.type~='fluid' then
     a.demands[#a.demands+1]={x=m.x,y=m.y,name=item.name,sources=m.unloads,targets=b.output_ports,machine_name=m.name,recipe=m.recipe,machine=m.name..'/'..m.recipe,output=true}
    end end
   end
  end
  s.phase='paths';s.index=1
 end
 while s.index<=#a.demands do
  local demand=a.demands[s.index]
  if not s.queue then
   s.searches=s.searches or {}
   local prior=demand.search_key and s.searches[demand.search_key]
   if prior then s.queue=prior.queue;s.seen=prior.seen;s.head=prior.head else
   s.queue={};s.seen={};s.head=1
   for _,p in ipairs(demand.sources) do local id=s.cells[key(p.x,p.y)]
    if id and not s.seen[id] then s.seen[id]=true;s.queue[#s.queue+1]=id end
   end
   end
   s.targets={};s.reached=false
   for _,p in ipairs(demand.targets or {{x=demand.x,y=demand.y}}) do local id=s.cells[key(p.x,p.y)];if id then s.targets[id]=true;if s.seen[id] then s.reached=true end end end
  end
  while s.queue[s.head] and not s.reached do
   if not work.consume(4) then return false end
   local id=s.queue[s.head];s.head=s.head+1
   for next_id in pairs(s.nodes[id].edges) do if not s.seen[next_id] and passes(s.nodes[id],next_id,demand.name) then s.seen[next_id]=true;s.queue[#s.queue+1]=next_id;if s.targets[next_id] then s.reached=true end end end
  end
  if not s.reached then s.issues[#s.issues+1]=(demand.machine and ((demand.output and 'Disconnected machine output: ' or 'Disconnected machine feed: ')..demand.machine..' / ') or 'Disconnected belt input: ')..demand.name..' at '..key(demand.x,demand.y)
   if demand.machine then s.issues.machine_details=s.issues.machine_details or {};s.issues.machine_details[#s.issues.machine_details+1]={name=demand.name,machine=demand.machine_name,recipe=demand.recipe,x=demand.x,y=demand.y,output=demand.output} end
  end
  if demand.search_key then s.searches[demand.search_key]={queue=s.queue,seen=s.seen,head=s.head} end
  s.queue=nil;s.seen=nil;s.index=s.index+1
 end
 -- Check what can reach each belt, not merely whether a required path exists.
 if a.material_sources then
  if not s.material_targets then
   s.material_targets={};s.material_order={};s.material_i=1;s.material_reported={}
   local function allowed(block,recipe)
    local result={}
    for _,v in ipairs(((block or {}).recipe_node or prototypes.recipe[recipe or ''] or {}).ingredients or {}) do if v.type~='fluid' then result[v.name]=true end end
    for _,p in ipairs((block or {}).inputs or {}) do result[p.ingredient]=true end
    return result
   end
   for bi,b in ipairs(a.blocks) do for _,p in ipairs(b.inputs or {}) do
    s.material_targets[#s.material_targets+1]={x=p.x,y=p.y,allowed=allowed(b,(b.recipe_node or {}).name),recipe=(b.recipe_node or {}).name,owner='block/'..bi}
   end end
   for mi,m in ipairs(s.machines) do
    for _,p in ipairs(m.feeds) do s.material_targets[#s.material_targets+1]={x=p.x,y=p.y,recipe=m.recipe,allowed=allowed(m.block and a.blocks[m.block],m.recipe),owner=m.block and ('block/'..m.block) or ('machine/'..mi)} end
   end
   for i,p in ipairs(a.outputs or {}) do if p.type=='item' then
    s.material_targets[#s.material_targets+1]={x=p.x,y=p.y,allowed={[p.name]=true},recipe=p.name,owner='output/'..i}
   end end
   for name in pairs(a.material_sources) do s.material_order[#s.material_order+1]=name end;table.sort(s.material_order)
  end
  while s.material_i<=#s.material_order do
   local name=s.material_order[s.material_i]
   if not s.material_queue then
    s.material_queue={};s.material_seen={};s.material_head=1;s.material_target_i=1
    for _,p in ipairs(a.material_sources[name]) do local id=s.cells[key(p.x,p.y)];if id and not s.material_seen[id] then s.material_seen[id]=true;s.material_queue[#s.material_queue+1]=id end end
   end
   while s.material_queue[s.material_head] do
    if not work.consume(4) then return false end
    local id=s.material_queue[s.material_head];s.material_head=s.material_head+1
    for next_id in pairs(s.nodes[id].edges) do if not s.material_seen[next_id] and passes(s.nodes[id],next_id,name) then s.material_seen[next_id]=true;s.material_queue[#s.material_queue+1]=next_id end end
   end
   while s.material_target_i<=#s.material_targets do
    if not work.consume(4) then return false end
    local target=s.material_targets[s.material_target_i];s.material_target_i=s.material_target_i+1
    local id=s.cells[key(target.x,target.y)];local signature=target.owner..'/'..name
    if id and s.material_seen[id] and not target.allowed[name] and not s.material_reported[signature] then
     s.material_reported[signature]=true
     s.issues[#s.issues+1]='Unexpected belt resource: '..name..' for '..(target.recipe or '?')..' at '..key(target.x,target.y)
     s.issues.material_details=s.issues.material_details or {};s.issues.material_details[#s.issues.material_details+1]={name=name,recipe=target.recipe,x=target.x,y=target.y}
    end
   end
   s.material_i=s.material_i+1;s.material_queue=nil;s.material_seen=nil
  end
 end
 return true,s.issues
end
work.register('validate-belts',step)
function M.check(entities,blocks,interface,independent,outputs)

 local sources={}
 for _,b in ipairs(blocks) do if b.product_out then for _,name in ipairs(b.products or {}) do
  sources[name]=sources[name] or {};for _,p in ipairs(b.mixed_output and {b.mixed_output} or resources.ports(b,name)) do sources[name][#sources[name]+1]=p end
 end end end
 for _,p in ipairs(interface or {}) do if p.type=='item' then sources[p.name]=sources[p.name] or {};sources[p.name][#sources[p.name]+1]=p end end
 if independent then for _,b in ipairs(blocks) do for _,p in ipairs(b.inputs or {}) do sources[p.ingredient]=sources[p.ingredient] or {};sources[p.ingredient][#sources[p.ingredient]+1]=p end end end
 local demands={}
 if not independent then for _,b in ipairs(blocks) do for _,p in ipairs(b.inputs or {}) do
  demands[#demands+1]={x=p.x,y=p.y,name=p.ingredient,search_key='external/'..p.ingredient,sources=sources[p.ingredient] or {}}
 end end end
 local members={};local by_id=true
 for _,b in ipairs(blocks) do if not b.machine_ids then by_id=false;break end end
 for bi,b in ipairs(blocks) do
  if by_id then for _,id in ipairs(b.machine_ids) do members[id]=bi end
  else for i=b.entity_first or 1,b.entity_last or 0 do members[i]=bi end end
 end
 return work.operation('validate-belts',nil,{entities=entities,demands=demands,blocks=blocks,members=members,by_id=by_id,material_sources=sources,outputs=outputs})
end
function M.links(entities,demands)
 if #demands==0 then return {} end
 return work.operation('validate-belts',nil,{entities=entities,demands=demands,blocks={},members={},skip_machines=true})
end
return M
