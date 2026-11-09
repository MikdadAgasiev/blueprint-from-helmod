-- Helmod counts are totals over recipe.base_time, not rates per second.
local M={}
local work=require('generation_work')
function M.flow(item,recipe)
 local period=tonumber(recipe.base_time) or 1
 if period<=0 then period=1 end
 if type(item.count)=='number' then return math.max(0,item.count)/period end
 if type(item.amount)=='number' then
  if recipe.base_time and type(recipe.count)=='number' then return math.max(0,item.amount*recipe.count)/period end
  -- Compatibility with callers supplying explicit per-second amount fields.
  return math.max(0,item.amount)
 end
 return 0
end
function M.belt(name)
 local p=prototypes.entity[name]
 return p and p.belt_speed and p.belt_speed*480 or 15
end
function M.split(recipe,settings,machines)
 local inputs,outputs={},{}
 for _,v in ipairs(recipe.ingredients or {}) do if v.type~='fluid' then inputs[#inputs+1]=v end end
 for _,v in ipairs(recipe.products or {}) do if v.type~='fluid' then outputs[#outputs+1]=v end end
 local total=math.max(1,machines or math.ceil((recipe.factory or {}).count or 1))
 local incoming=M.belt(settings.belt_in or 'transport-belt')
 local outgoing=M.belt(settings.belt_out or 'transport-belt')
 local demands={}
 for i,v in ipairs(inputs) do
  local share=1
  -- Three/four ingredient templates place each pair on opposite belt lanes.
  if #inputs>=3 and (i%2==0 or inputs[i+1]) then share=0.5 end
  local physical=incoming*share
  if #inputs==2 and total>1 then physical=math.min(physical,incoming*total/(2*math.ceil(total/2))) end
  demands[#demands+1]={item=v.name,side='input',flow=M.flow(v,recipe),capacity=incoming*share,single_block_capacity=physical}
 end
 local output=0
 for _,v in ipairs(outputs) do output=output+M.flow(v,recipe) end
 demands[#demands+1]={item='all products',side='output',flow=output,capacity=outgoing*(recipe.parallel_outputs and 2 or 1)}
 for groups=1,total do
  local largest=math.ceil(total/groups)/total;local fits=true
  for _,d in ipairs(demands) do
   if d.flow*largest>d.capacity+1e-8 then fits=false;break end
   -- A paired block cannot put more than half a belt on either machine bank.
   -- Do not rely on the legacy odd-bank output loop to recover lost capacity.
   if d.side=='output' and #outputs==1 and #inputs<=2 then
    local subgroup=math.ceil(total/groups)
    if subgroup>1 and d.flow*math.ceil(subgroup/2)/total>outgoing/(recipe.parallel_outputs and 1 or 2)+1e-8 then fits=false;break end
   end
   if d.side=='input' and #inputs==2 then
    local subgroup=math.ceil(total/groups)
    if subgroup>1 and d.flow*math.ceil(subgroup/2)/total>incoming/2+1e-8 then fits=false;break end
   end
  end
  if fits then return groups,demands end
 end
 return total,demands,true
end
work.register('automatic-belts',function(args,state)
 local names=args.names
 local fastest=names[#names]
 if not state.index then
  state.index=1;state.input=1;state.output=1
  local top_speed=M.belt(fastest)
  local function external(index,flows)
   for _,flow in ipairs(flows) do if flow.type=='item' then
    local lanes=math.ceil(flow.rate/top_speed-1e-9)
    while index<#names and math.ceil(flow.rate/M.belt(names[index])-1e-9)>lanes do index=index+1 end
   end end
   return index
  end
  state.input=external(state.input,args.imports)
  state.output=external(state.output,args.exports)
 end
 while state.index<=#args.recipes do
  if not work.consume(64) then return false end
  local recipe=args.recipes[state.index]
  local baseline,_,overloaded=M.split(recipe,{belt_in=fastest,belt_out=fastest})
  if overloaded then return true,{input=fastest,output=fastest,fastest=fastest} end
  local function fits(input,output)
   local count,_,limit=M.split(recipe,{belt_in=input,belt_out=output})
   return count<=baseline and not limit
  end
  while state.input<#names and not fits(names[state.input],fastest) do state.input=state.input+1 end
  while state.output<#names and not fits(fastest,names[state.output]) do state.output=state.output+1 end
  state.index=state.index+1
  if work.is_active() and state.index<=#args.recipes then return false end
 end
 return true,{input=names[state.input],output=names[state.output],fastest=fastest}
end)
function M.auto_belts(recipes,names,imports,exports)
 return work.operation('automatic-belts',nil,{recipes=recipes,names=names,imports=imports,exports=exports})
end
function M.inserter_rate(name,force)
 local p=prototypes.entity[name]
 if not p or not p.get_inserter_rotation_speed then return 0 end
 local rotation=p.get_inserter_rotation_speed('normal') or 0
 if rotation<=0 then return 0 end
 local bonus=0
 if force then bonus=p.uses_inserter_stack_size_bonus and force.inserter_stack_size_bonus or force.bulk_inserter_capacity_bonus end
 local stack=1+(p.inserter_stack_size_bonus or 0)+(bonus or 0)
 -- Two half-turns and a small allowance for pickup; belt contents can still limit it.
 return stack*60/(2*math.ceil(0.5/rotation)+2)
end
return M
