local M={}
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
-- Prefer the source dedicated to this receiver. Equal merging can otherwise
-- draw excess from a shared source while a dedicated source backs up.
function M.merge(existing,rate,load,direction,dx,dy)
 local weight,total=0,0
 for _,part in ipairs(existing or {}) do
  total=total+part.rate
  weight=weight+part.rate*part.rate/math.max(part.load,1e-9)
 end
 if total<=0 then return nil end
 local prior=weight/total;local incoming=rate/math.max(load,1e-9)
 if math.abs(prior-incoming)<1e-8 then return nil end
 return M.half(direction,dx,dy,incoming>prior)
end
function M.half(direction,dx,dy,incoming)
 local v=vectors[direction]
 local left=dx*v[2]-dy*v[1]>0
 if not incoming then left=not left end
 return left and 'left' or 'right'
end
-- A transport allocation built by exhausting a source or a receiver per edge
-- is a forest. Remove its leaves to obtain compatible splitter priorities:
-- a sole receiver is supplied first; a sole supplier is drained first.
function M.tree(sources,sinks)
 local sd,td,done={},{},{};local remaining=0
 for _,source in ipairs(sources) do sd[source]=#source.links;remaining=remaining+#source.links end
 for _,sink in ipairs(sinks) do td[sink]=#sink.links end
 local rank=0
 while remaining>0 do
  local selected
  local function first(links)for _,edge in ipairs(links) do if not done[edge] then return edge end end end
  for _,sink in ipairs(sinks) do if td[sink]==1 and not sink.terminal then selected=first(sink.links);break end end
  if not selected then for _,source in ipairs(sources) do if sd[source]==1 then selected=first(source.links);break end end end
  if not selected then for _,sink in ipairs(sinks) do if td[sink]==1 then selected=first(sink.links);break end end end
  if not selected then return false end
  rank=rank+1;selected.priority_rank=rank;done[selected]=true;remaining=remaining-1
  sd[selected.source]=sd[selected.source]-1;td[selected.target]=td[selected.target]-1
 end
 local function order(a,b)return a.priority_rank<b.priority_rank end
 for _,source in ipairs(sources) do table.sort(source.links,function(a,b)if not not a.terminal~=not not b.terminal then return not a.terminal end;return order(a,b) end) end
 for _,sink in ipairs(sinks) do table.sort(sink.links,order) end
 return true
end
return M
