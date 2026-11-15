-- Keep a common export bank, ordered along its actual production sources.
local M={}
local function median(values)
 if #values==0 then return end
 table.sort(values,function(a,b)return a.y<b.y end)
 local total=0;for _,v in ipairs(values) do total=total+v.weight end
 local sum=0;for _,v in ipairs(values) do sum=sum+v.weight;if sum>=total/2 then return v.y end end
end
function M.place(banks,samples,top,bottom,fallback)
 local ranks,total_height={},0
 for i,bank in ipairs(banks) do
  local values={};local weight=0
  for _,p in ipairs(samples[bank.name] or {}) do
   local w=p.weight or 1
   if w>0 then values[#values+1]={y=p.y,weight=w};weight=weight+w end
  end
  ranks[bank]={target=median(values),weight=weight,index=i,offset=total_height}
  total_height=total_height+bank.height
 end
 table.sort(banks,function(a,b)
  local x,y=ranks[a],ranks[b]
  local ay,by=x.target or fallback+x.offset,y.target or fallback+y.offset
  if ay~=by then return ay<by end
  return x.index<y.index
 end)
 local shifts,offset={},0
 for _,bank in ipairs(banks) do
  local rank=ranks[bank]
  if rank.target then shifts[#shifts+1]={y=rank.target-offset-(bank.anchor or 0),weight=rank.weight} end
  offset=offset+bank.height
 end
 local start=median(shifts)
 local extent=total_height-(banks[#banks] and banks[#banks].tail_space or 0)
 if not start or extent>bottom-top then return fallback end
 return math.max(top,math.min(bottom-extent,math.floor(start)))
end
return M
