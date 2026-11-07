-- Deterministic, serializable cooperative work. No closures or Lua stacks in storage.
-- Completed calls are replayed from snapshots; unfinished searches keep plain data.
local M={}
local active,stack,budget
local pending={}
local handlers={}
local standalone_routes={}
function M.layout_begin(index,limit)
 local state=active
 if not state then if index==1 then standalone_routes={} end;state=standalone_routes end
 state.route_scope=index;state.route_limit=limit
 state.route_counts=state.route_counts or {};state.route_counts[index]=state.route_counts[index] or 0
end
function M.route_visit()
 local state=active or standalone_routes;local scope=state.route_scope
 if not scope then return true end
 local count=state.route_counts[scope]
 if state.route_limit and count>=state.route_limit then
  state.route_limited=state.route_limited or {};state.route_limited[scope]=true;return false
 end
 state.route_counts[scope]=count+1;return true
end
function M.layout_end()
 local state=active or standalone_routes;state.route_scope=nil;state.route_limit=nil
end
function M.register(label,fn) handlers[label]=fn end
handlers['route-attempt']=function()
 if not M.consume(16) then return false end
 local state=active or standalone_routes;local scope=state.route_scope
 return true,not (scope and state.route_limit and state.route_counts[scope]>=state.route_limit)
end
-- Cache the admission decision: reading the live cumulative counter on replay
-- would skip previously completed children and corrupt the replay sequence.
function M.route_attempt()return M.operation('route-attempt',nil,{})end

local unpack=table.unpack or unpack
local function pack(...) return {n=select('#',...),...} end
function M.copy(value,seen)
  if type(value)~='table' then return value end
  seen=seen or {};if seen[value] then return seen[value] end
  local out={};seen[value]=out
  for k,v in pairs(value) do out[M.copy(k,seen)]=M.copy(v,seen) end
  return out
end
-- Only fields used by the current planner belong in a generation job. Helmod's
-- unrelated model/UI/cache data must not be copied into every candidate snapshot.
local function quality_name(value)
  if type(value)=='string' or value==nil then return value end
  return value.name
end
local function module_inputs(values)
  local result={}
  for _,v in pairs(values or {}) do result[#result+1]={name=v.name,quality=quality_name(v.quality),amount=v.amount,count=v.count} end
  return result
end
local function effect_inputs(values)
  if not values then return end
  local result={};for _,key in ipairs({'speed','productivity','consumption','pollution','quality'}) do result[key]=values[key] end
  return result
end
function M.recipe_inputs(recipes)
  local out={}
  for i,r in ipairs(recipes) do
    local n={name=r.name,class=r.class,count=r.count,base_time=r.base_time,
      factory={name=(r.factory or {}).name,count=(r.factory or {}).count,quality=quality_name((r.factory or {}).quality),
        modules=module_inputs((r.factory or {}).modules),effects=effect_inputs((r.factory or {}).effects)},quality=quality_name(r.quality)}
    n.beacons={}
    for _,b in ipairs(r.beacons or (r.beacon and {r.beacon}) or {}) do
      n.beacons[#n.beacons+1]={name=b.name,quality=quality_name(b.quality),combo=b.combo,count=b.count,amount=b.amount,
        per_factory=b.per_factory,per_factory_constant=b.per_factory_constant,modules=module_inputs(b.modules)}
    end
    for _,field in ipairs({'ingredients','products'}) do if r[field] then
      n[field]={}
      for k,v in pairs(r[field]) do n[field][k]={name=v.name,type=v.type,count=v.count,amount=v.amount,quality=quality_name(v.quality)} end
    end end
    out[i]=n
  end
  return out
end
function M.load_budget(mode) return ({minimal=64,normal=250,fast=750})[mode] or 250 end
function M.begin(cache,limit)
  active=cache;stack={{node=cache,index=0}};budget=limit or 250
end
function M.finish() active=nil;stack=nil;budget=nil end
function M.is_pending(err) return err==pending end
function M.consume(cost)
  if not active then return true end
  cost=cost or 1
  if budget<cost then return false end
  budget=budget-cost;active.work_units=(active.work_units or 0)+cost;return true
end
local function enter(label)
  local parent=stack[#stack];parent.index=parent.index+1
  parent.node.children=parent.node.children or {}
  local node=parent.node.children[parent.index]
  if not node then node={label=label};parent.node.children[parent.index]=node end
  assert(node.label==label,'generation replay diverged: '..label)
  return node
end
local function result(node,readonly)
  local r=readonly and node.result or M.copy(node.result);return unpack(r,1,r.n)
end
-- A replayable stage may call other cached stages or resumable operations.
function M.cached(label,fn,readonly)
  if not active then return fn() end
  local node=enter(label)
  if node.ready then return result(node,readonly) end
  if not M.consume() then error(pending,0) end
  stack[#stack+1]={node=node,index=0}
  local r=pack(fn())
  stack[#stack]=nil
  node.result=M.copy(r);node.ready=true;node.children=nil
  return unpack(r,1,r.n)
end
-- fn(state) returns done, ...; all continuation state must be plain serializable data.
local function complete(node,r)
  local out={n=r.n-1};for i=2,r.n do out[i-1]=r[i] end
  node.result=M.copy(out);node.ready=true;node.state=nil;node.arguments=nil;node.resume_label=nil
  return out
end
function M.operation(label,fn,arguments)
  if not active then
    local done,a,b,c
    if arguments then done,a,b,c=handlers[label](arguments,{}) else done,a,b,c=fn({}) end
    assert(done,'synchronous work must complete');return a,b,c
  end
  local node=enter(label)
  if node.ready then return result(node) end
  node.state=node.state or {}
  local r
  if arguments then
    node.arguments=arguments;node.resume_label=label
    r=pack(handlers[label](arguments,node.state))
  else r=pack(fn(node.state)) end
  if not r[1] then
    if arguments then active.pending=node end
    error(pending,0)
  end
  local out=complete(node,r)
  return unpack(out,1,out.n)
end
-- Resume just the suspended search, without replaying the blueprint builder.
-- Registered functions are runtime-only; saved jobs contain plain arguments/state.
function M.resume_pending()
  local node=active.pending
  if not node then return end
  local handler=handlers[node.resume_label]
  assert(handler,'missing generation continuation: '..tostring(node.resume_label))
  active.direct_resumes=(active.direct_resumes or 0)+1
  local r=pack(handler(node.arguments,node.state))
  if not r[1] then error(pending,0) end
  complete(node,r);active.pending=nil
  -- Finish the search this tick; replay/copy its parent on the next tick.
  -- Combining both creates avoidable bursts at stage boundaries.
  error(pending,0)
end
function M.replay() if active then active.builder_calls=(active.builder_calls or 0)+1 end end
function M.layout_seen(signature,index)
  if not active then return false end
  active.layouts=active.layouts or {}
  local previous=active.layouts[signature]
  if previous and previous~=index then active.duplicates=(active.duplicates or 0)+1;return true end
  active.layouts[signature]=index
  return false
end
function M.pruned() if active then active.pruned=(active.pruned or 0)+1 end end
function M.phase(key,fraction,detail)
  if not active then return end
  -- Replaying earlier stages must not move the displayed progress backwards.
  if fraction>=(active.fraction or 0) then
    active.phase=key;active.fraction=fraction;active.detail=detail
  end
end
return M
