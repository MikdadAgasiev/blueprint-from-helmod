-- Deterministic, serializable cooperative work. No closures or Lua stacks in storage.
-- Completed calls are replayed from snapshots; unfinished searches keep plain data.
local M={}
local active,stack,budget,copy_limit,copy_available
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

-- Charge section transitions to the deterministic work budget. Do not force
-- idle ticks when there is still capacity to continue the next section.
handlers['section-boundary']=function(_,state)
 if not active or state.waited then return true end
 state.waited=true
 return M.consume(1024)
end
function M.section_boundary() return M.operation('section-boundary',nil,{}) end

local unpack=table.unpack or unpack
local function pack(...) return {n=select('#',...),...} end
function M.copy(value,seen)
  if type(value)~='table' then return value end
  seen=seen or {};if seen[value] then return seen[value] end
  local out={};seen[value]=out
  for key,item in pairs(value) do
    if type(key)=='table' then key=M.copy(key,seen) end
    if type(item)=='table' then item=M.copy(item,seen) end
    out[key]=item
  end
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
function M.load_budget(mode) return ({minimal=1000,normal=18000,fast=36000})[mode] or 18000 end
function M.begin(cache,limit)
  active=cache;stack={{node=cache,index=0}};budget=limit or 250;copy_limit=math.max(256,budget*4);copy_available=copy_limit
end
function M.finish() active=nil;stack=nil;budget=nil;copy_limit=nil;copy_available=nil end
function M.is_pending(err) return err==pending end
function M.is_active() return active~=nil end
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
-- Copy large snapshots cooperatively. Key lists survive save/load; no Lua stacks
-- or next() cursors are retained. Table keys, aliases and cycles retain identity.
local function copy_step(value,s)
  local function intern(v)
    if type(v)~='table' then return v end
    if s.seen[v] then return s.seen[v] end
    local out={};s.seen[v]=out;s.tail=s.tail+1
    s.sources[s.tail]=v;s.targets[s.tail]=out
    return out
  end
  local used=0;local limit=copy_available
  local function pause()copy_available=math.max(0,copy_available-used);return false end
  if not s.seen then
    s.seen={};s.sources={};s.targets={};s.tail=0;s.head=1
  end
  -- Seed borrowed entity identities with the same quota as copied fields.
  -- A restore can reference several thousand immutable entity records.
  if s.borrowed then
    local index=s.borrowed_index or 1
    while index<=#s.borrowed do
      if used>=limit then s.borrowed_index=index;return pause() end
      local atom=s.borrowed[index]
      s.seen[atom]=atom;index=index+1;used=used+1
    end
    s.borrowed=nil;s.borrowed_index=nil
  end
  if not s.root_ready then s.root=intern(value);s.root_ready=true end
  while s.head<=s.tail do
    local source,target=s.sources[s.head],s.targets[s.head]
    if not s.keys then
      s.keys={};for k in pairs(source) do s.keys[#s.keys+1]=k end
      s.index=1;used=used+1
    end
    while s.index<=#s.keys do
      if used>=limit then return pause() end
      local k=s.keys[s.index];s.index=s.index+1;used=used+1
      target[intern(k)]=intern(source[k])
    end
    s.keys=nil;s.head=s.head+1
    if used>=limit then return pause() end
  end
  -- Release the temporary identity map in bounded batches as well.
  s.clean=s.clean or 1
  while s.clean<=s.tail do
    if used>=limit then return pause() end
    local i=s.clean;s.clean=i+1;used=used+1
    s.seen[s.sources[i]]=nil;s.sources[i]=nil;s.targets[i]=nil
  end
  copy_available=math.max(0,copy_available-used)
  return true,s.root
end
function M.copy_step(value,state)
  if not active then return true,M.copy(value) end
  return copy_step(value,state)
end
local function pump_copy(node)
  local done,value=copy_step(node.copy_source,node.copy_state)
  if not done then active.pending=node;return false end
  local kind,source=node.copy_kind,node.copy_source
  node.copy_kind=nil;node.copy_source=nil;node.copy_state=nil
  if kind=='read' then node.read_result=value
  else
    node.result=value;node.ready=true;node.children=nil
    node.state=nil;node.arguments=nil;node.resume_label=nil
    -- Deliver the original working result once; the cached snapshot is isolated.
    node.read_result=source
  end
  return true
end
local function start_copy(node,kind,source,borrowed)
  node.copy_kind=kind;node.copy_source=source;node.copy_state={borrowed=borrowed}
  return pump_copy(node)
end
local function working_result(node)
  local r=node.read_result;node.read_result=nil;return unpack(r,1,r.n)
end
local function result(node,readonly,borrowed)
  if readonly then return unpack(node.result,1,node.result.n) end
  if node.read_result then return working_result(node) end
  -- Replay restoration must be atomic. Yielding between completed prefix
  -- results causes their mutable copies to be recreated exponentially.
  local seen={}
  for _,value in ipairs(borrowed or {}) do seen[value]=value end
  local restored=M.copy(node.result,seen)
  return unpack(restored,1,restored.n)
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
  if readonly then
    node.result=r;node.ready=true;node.children=nil
    return unpack(r,1,r.n)
  end
  if not start_copy(node,'store',r) then error(pending,0) end
  return working_result(node)
end
-- A fork borrows an immutable stage input and produces a private working copy.
function M.fork(label,value,borrowed)
  if not active then return M.copy(value) end
  local node=enter(label)
  if not node.ready then node.result={n=1,value};node.borrowed=borrowed;node.ready=true end
  return result(node,false,node.borrowed)
end
-- fn(state) returns done, ...; all continuation state must be plain serializable data.
local function complete(node,r)
  local out={n=r.n-1};for i=2,r.n do out[i-1]=r[i] end
  if node.readonly then
    node.result=out;node.ready=true;node.children=nil
    node.state=nil;node.arguments=nil;node.resume_label=nil
    return true
  end
  for i=1,out.n do if type(out[i])=='table' then
    node.copy_kind='store';node.copy_source=out;node.copy_state={};active.pending=node
    return false
  end end
  return start_copy(node,'store',out)
end
function M.operation(label,fn,arguments,readonly)
  if not active then
    local done,a,b,c
    if arguments then done,a,b,c=handlers[label](arguments,{}) else done,a,b,c=fn({}) end
    assert(done,'synchronous work must complete');return a,b,c
  end
  local node=enter(label)
  if node.ready then return result(node,node.readonly) end
  node.readonly=readonly or false
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
  if not complete(node,r) then error(pending,0) end
  if node.readonly then return result(node,true) end
  return working_result(node)
end
-- Shallow snapshots retain only explicitly immutable record values. Their
-- outer maps and arrays are private, and traversal is bounded across ticks.
handlers['shallow-snapshot']=function(args,state)
 if not state.fields then
  state.fields={};for field in pairs(args) do state.fields[#state.fields+1]=field end
  state.field=1;state.result={}
 end
 while state.field<=#state.fields do
  local field=state.fields[state.field];local value=args[field]
  if type(value)~='table' then state.result[field]=value;state.field=state.field+1
  else
   if not state.keys then
    state.keys={};for k in pairs(value) do state.keys[#state.keys+1]=k end
    state.index=1;state.result[field]={}
   end
   while state.index<=#state.keys do
    if not M.consume() then return false end
    local k=state.keys[state.index];state.result[field][k]=value[k];state.index=state.index+1
   end
   state.keys=nil;state.field=state.field+1
  end
 end
 return true,state.result
end
function M.shallow_snapshot(value)return M.operation('shallow-snapshot',nil,value,true)end
-- Resume just the suspended search, without replaying the blueprint builder.
-- Registered functions are runtime-only; saved jobs contain plain arguments/state.
function M.resume_pending()
  local node=active.pending
  if not node then return end
  if node.copy_kind then
    if pump_copy(node) then active.pending=nil;return end
    error(pending,0)
  end
  local handler=handlers[node.resume_label]
  assert(handler,'missing generation continuation: '..tostring(node.resume_label))
  active.direct_resumes=(active.direct_resumes or 0)+1
  local r=pack(handler(node.arguments,node.state))
  if not r[1] then error(pending,0) end
  if complete(node,r) then active.pending=nil;return end
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
