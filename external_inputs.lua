local M={}
local templates=require('balancer_templates')
local capacity=require('capacity')
local work=require('generation_work')
local containers=require('container_distribution')
local feedback=require('balancer_feedback')
local feedback_cache={}
function M.plan(entities,blocks,ports,settings,en,fluid_clearance)
 local container_context=settings.distribution_mode=='containers' and containers.context(settings)
 local produced,groups,fluid,order={},{},{},{}
 for _,b in ipairs(blocks) do b.external_inputs={};b.external_fluid_inputs={};for _,v in pairs((b.recipe_node or {}).products or {}) do produced[v.name]=true end end
 for bi,b in ipairs(blocks) do for _,input in ipairs(b.inputs or {}) do if not input.array_local and not produced[input.ingredient] then
  local name=input.ingredient
  if not groups[name] then groups[name]={};order[#order+1]=name end
  local rate=0;for _,v in pairs((b.recipe_node or {}).ingredients or {}) do if v.name==name then rate=rate+capacity.flow(v,b.recipe_node) end end
  groups[name][#groups[name]+1]={input=input,block=bi,rate=input.array_supply_rate or rate}
 end end end
 table.sort(order)
 for _,p in ipairs(ports) do if p.kind=='input' and not produced[p.fluid] then fluid[p.fluid]=true end end
 local left,top=math.huge,math.huge
 for _,e in ipairs(entities) do local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end;left=math.min(left,math.floor(e.position.x-w/2+.001));top=math.min(top,math.floor(e.position.y-h/2+.001)) end
 local entries={};local y=top;local face=left-6-(fluid_clearance or 0)
 local function add(n,x,y,d,kind)
  entities[#entities+1]={entity_number=en,name=n,position={x=x+.5,y=y+.5},direction=d,type=kind};en=en+1
 end
 local function equipment(t)
  local split=settings.belt_in:gsub('transport%-belt','splitter')
  local ug=settings.belt_in:gsub('transport%-belt','underground-belt')
  if not prototypes.entity[split] or prototypes.entity[split].type~='splitter' or not prototypes.entity[ug] or prototypes.entity[ug].type~='underground-belt' then return end
  return split,ug
 end
 local function emit(m,n,right,py,resource)
  if container_context and m==1 and n==1 then
   -- A single feed can continue straight to its only destination.
   local inlet_x=right-2
   face=math.min(face,inlet_x)
   for x=inlet_x,right do add(settings.belt_in,x,py,4) end
   return {{x=inlet_x,y=py,direction=4}},{{x=right,y=py,direction=4}},1
  end
  if container_context then
   local inputs,outputs,height,next_id=containers.emit(entities,en,container_context,settings,m,n,right,py,resource)
   en=next_id;face=math.min(face,inputs[1].x)
   return inputs,outputs,height
  end
  local template_key=m..':'..n
  local t=templates[template_key];local split,ug=equipment()
  assert(t and split and ug,'No supported external balancer '..m..' to '..n)
  -- The 2->3 feedback distributor is verified with unequal sink demands.
  -- Retain other templates until their dynamic capacity is verified as well.
  if not feedback_cache[template_key] then feedback_cache[template_key]=template_key=='2:3' and feedback.priorities(t) or {} end
  local minx,maxx,maxy=math.huge,-math.huge,-math.huge
  for _,e in ipairs(t.entities) do local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end;minx=math.min(minx,e.position.x-w/2);maxx=math.max(maxx,e.position.x+w/2);maxy=math.max(maxy,e.position.y+h/2) end
  local x=right-maxx;local inlet_x=math.floor(x+minx)-2
  face=math.min(face,inlet_x)
  for template_index,original in ipairs(t.entities) do
   local e=work.copy(original);e.entity_number=en;en=en+1
   e.output_priority=feedback_cache[template_key][template_index] or e.output_priority
   e.name=e.name=='transport-belt' and settings.belt_in or e.name=='splitter' and split or ug
   e.position.x=e.position.x+x;e.position.y=e.position.y+py;entities[#entities+1]=e
  end
  local inputs,outputs={},{}
  for _,p in ipairs(t.inputs) do
   for xx=inlet_x,x+p.x-1 do add(settings.belt_in,xx,py+p.y,4) end
   inputs[#inputs+1]={x=inlet_x,y=py+p.y,direction=4}
  end
  for _,p in ipairs(t.outputs) do outputs[#outputs+1]={x=x+p.x,y=py+p.y,direction=4} end
  return inputs,outputs,maxy
 end
 local belt_capacity=container_context and container_context.capacity or capacity.belt(settings.belt_in)
 for _,name in ipairs(order) do
  local targets=groups[name];local resource_y=y;local first=#entries+1;local sockets={};local total=0
  if container_context then for _,target in ipairs(targets) do
   if target.rate>container_context.capacity+1e-8 then error({'bfh.container-loader-slow',name},0) end
  end end
  for start=1,#targets,8 do
   local n=math.min(8,#targets-start+1);local demand=0
   for i=start,start+n-1 do demand=demand+targets[i].rate end
   total=total+demand
   local m=math.max(1,math.ceil(demand/belt_capacity-1e-8))
   local inputs,outputs,height=emit(m,n,left-math.max(5,n+2),y,name)
   for _,p in ipairs(inputs) do p.rate=demand/m;p.ingredient=name;sockets[#sockets+1]=p end
   for i,p in ipairs(outputs) do local target=targets[start+i-1]
    entries[#entries+1]={type='item',name=name,x=p.x,y=p.y,direction=p.direction or 4,input=target.input,block=target.block}
   end
   y=y+height+3
  end
  -- Aggregate the inputs of consumer banks as well. A ninth consumer must
  -- not create a second external belt when the whole resource fits one.
  local required=math.max(1,math.ceil(total/belt_capacity-1e-8))
  while required<=8 and #sockets>required do
   local chunks={};local next_count=0
   for start=1,#sockets,8 do
    local n=math.min(8,#sockets-start+1);local demand=0
    for i=start,start+n-1 do demand=demand+sockets[i].rate end
    local m=math.max(1,math.ceil(demand/belt_capacity-1e-8));next_count=next_count+m
    chunks[#chunks+1]={start=start,n=n,m=m,demand=demand}
   end
   if next_count>=#sockets then break end
   local right=face-4;local py=resource_y;local next_sockets={}
   for _,chunk in ipairs(chunks) do
    local inputs,outputs,height=emit(chunk.m,chunk.n,right,py,name)
    for _,p in ipairs(inputs) do p.rate=chunk.demand/chunk.m;p.ingredient=name;next_sockets[#next_sockets+1]=p end
    for i,p in ipairs(outputs) do entries[#entries+1]={type='item',name=name,x=p.x,y=p.y,direction=p.direction or 4,input=sockets[chunk.start+i-1]} end
    py=py+height+3
   end
   y=math.max(y,py);sockets=next_sockets
  end
  for i=first,#entries do entries[i].inlets=sockets end
 end
 local aligned={}
 for _,entry in ipairs(entries) do for _,input in ipairs(entry.inlets or {}) do
  local k=input.x..','..input.y
  if not aligned[k] then
   aligned[k]=true
   for xx=face,input.x-1 do add(settings.belt_in,xx,input.y,4) end
   input.x=face
  end
 end end
 local names={};for n in pairs(fluid) do names[#names+1]=n end;table.sort(names)
 for _,name in ipairs(names) do
  entries[#entries+1]={type='fluid',name=name,x=face,y=y}
  ports[#ports+1]={x=face,y=y,dir=4,fluid=name,kind='input',block=0,external=true}
  blocks[1].external_fluid_inputs[#blocks[1].external_fluid_inputs+1]={x=face,y=y,fluid=name,direction=4};y=y+3
 end
 return entries,face,en
end
function M.interface(plan)
 local result,seen={},{}
 for _,port in ipairs(plan) do
  if port.type=='fluid' then result[#result+1]=port
  else for _,input in ipairs(port.inlets or {port}) do
   local k=input.x..','..input.y
   if not seen[k] then seen[k]=true;result[#result+1]={type='item',name=port.name,x=input.x,y=input.y,block=port.block} end
  end end
 end
 return result
end
return M
