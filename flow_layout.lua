-- Placement affinities are bounded by actual recipe flow, not an all-to-all
-- attraction between every block that happens to mention the same material.
local M={}
local capacity=require('capacity')
function M.wires(blocks)
 local items={};local wires={};local bound={};local spent={}
 for i,b in ipairs(blocks) do for oi,p in ipairs(b.layout_output_ports or {}) do if p.flow_edge then bound[p.flow_edge]={source=i,output=oi,rate=p.rate or 0} end end end
 for i,b in ipairs(blocks) do for ii,p in ipairs(b.inputs or {}) do local source=p.flow_edge and bound[p.flow_edge]
  if source and source.source~=i then
   wires[#wires+1]={source=source.source,output=source.output,target=i,input=ii,weight=1,rate=p.graph_rate or p.layout_rate or source.rate}
   spent[source.source]=spent[source.source] or {};local name=p.ingredient;spent[source.source][name]=(spent[source.source][name] or 0)+(p.graph_rate or p.layout_rate or source.rate)
  end
 end end
 for i,b in ipairs(blocks) do
  local r=b.recipe_node or {}
  if b.product_out then for _,p in ipairs(r.products or {}) do if p.type~='fluid' then
   local a=items[p.name] or {sources={},sinks={}};items[p.name]=a
   a.sources[#a.sources+1]={index=i,remaining=math.max(0,capacity.flow(p,r)-((spent[i] or {})[p.name] or 0))}
  end end end
  for ii,p in ipairs(b.inputs or {}) do if not (p.flow_edge and bound[p.flow_edge]) then
   local rate=0;for _,v in ipairs(r.ingredients or {}) do if v.name==p.ingredient then rate=rate+capacity.flow(v,r) end end
   local a=items[p.ingredient] or {sources={},sinks={}};items[p.ingredient]=a
   a.sinks[#a.sinks+1]={index=i,input=ii,rate=p.graph_rate or p.layout_rate or rate}
  end end
 end
 local names={};for name in pairs(items) do names[#names+1]=name end;table.sort(names)
 for _,name in ipairs(names) do local a=items[name]
  local supply,need=0,0;for _,p in ipairs(a.sources) do supply=supply+p.remaining end;for _,p in ipairs(a.sinks) do need=need+p.rate end
  local surplus=supply-need
  -- Do not attract intermediate consumers to a complete terminal-production
  -- bank whose whole output is already needed as the plan's final product.
  if surplus>1e-8 then for _,p in ipairs(a.sources) do if math.abs(p.remaining-surplus)<1e-8 then p.remaining=0;break end end end
  table.sort(a.sinks,function(x,y)if x.rate~=y.rate then return x.rate>y.rate end;if x.index~=y.index then return x.index<y.index end;return x.input<y.input end)
  for _,sink in ipairs(a.sinks) do
   local remaining=sink.rate;local input=blocks[sink.index].inputs[sink.input]
   while remaining>1e-8 do
    local chosen,score
    for _,source in ipairs(a.sources) do if source.index~=sink.index and source.remaining>1e-8 then
     local p=blocks[source.index].product_out
     local distance=math.abs(p.x-input.x)+math.abs(p.y-input.y)
     -- Prefer complete feeds; splitting one demand into many tiny affinities
     -- makes both the seed and the later routing unnecessarily diffuse.
     local value=distance+(source.remaining+1e-8<remaining and 100000 or 0)
     if not score or value<score then chosen,score=source,value end
    end end
    if not chosen then break end
    local rate=math.min(remaining,chosen.remaining)
    wires[#wires+1]={source=chosen.index,target=sink.index,input=sink.input,weight=rate/math.max(sink.rate,1e-8),rate=rate}
    chosen.remaining=chosen.remaining-rate;remaining=remaining-rate
   end
  end
 end
 return wires
end
return M
