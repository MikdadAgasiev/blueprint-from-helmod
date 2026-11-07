-- Preserve the first collinear mouth seen by every existing input. Complete
-- non-overlapping pairs may follow each other; opposite/overlapping pairs may not.
local M={}
function M.safe(cell,x,y,dx,dy,length,d,name,reach)
 local mouths={}
 for i=-reach,length+reach do
  local nd,kind,tier=cell(x+dx*i,y+dy*i)
  if tier==name and (kind=='ug_in' or kind=='ug_out') and nd~=nil and nd%8==d%8 then
   if i>=0 and i<=length then return false end
   mouths[i]={d=nd,kind=kind}
  end
 end
 for i,m in pairs(mouths) do if m.kind=='ug_in' then
  local sign=m.d==d and 1 or -1
  for step=1,reach do local j=i+sign*step
   if j==0 or j==length then return false end
   if mouths[j] then break end
  end
 end end
 return true
end
return M
