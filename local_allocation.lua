-- Reassign already feasible supplies by balanced exchanges instead of long late feeds.
local M={}
local work=require('generation_work')
local function step(a,s)
 s.matrix=s.matrix or work.copy(a.matrix);local m=s.matrix;local n,k=#m,#a.costs[1]
 s.pass=s.pass or 1;s.i=s.i or 1;s.j=s.j or 2;s.c=s.c or 1;s.d=s.d or 1
 while s.pass<=12 do
  while s.i<n do while s.j<=n do while s.c<=k do while s.d<=k do
   if not work.consume(1) then return false end
   local i,j,c,d=s.i,s.j,s.c,s.d
   local amount=math.min(m[i][c],m[j][d])
   local whole_swap=a.locked and a.locked[i] and a.locked[j] and math.abs(m[i][c]-m[j][d])<1e-8
   if (not (a.locked and (a.locked[i] or a.locked[j])) or whole_swap) and c~=d and amount>1e-8 then
    local improvement=a.costs[i][c]+a.costs[j][d]-a.costs[i][d]-a.costs[j][c]
    if improvement>1e-8 then
     local before=(m[i][d]<=1e-8 and 1 or 0)+(m[j][c]<=1e-8 and 1 or 0)
     local after=(m[i][c]<=amount+1e-8 and 1 or 0)+(m[j][d]<=amount+1e-8 and 1 or 0)
     if improvement*amount>8*(before-after)+1e-8 then
      m[i][c]=m[i][c]-amount;m[j][d]=m[j][d]-amount;m[i][d]=m[i][d]+amount;m[j][c]=m[j][c]+amount;s.changed=true
     end
    end
   end
   s.d=s.d+1
  end;s.d=1;s.c=s.c+1 end;s.c=1;s.j=s.j+1 end;s.j=s.i+2;s.i=s.i+1 end
  if not s.changed then break end
  s.pass=s.pass+1;s.i=1;s.j=2;s.c=1;s.d=1;s.changed=false
 end
 return true,m
end
work.register('local-flow-exchanges',step)
function M.optimize(matrix,costs,locked)
 if #matrix<2 or #costs[1]<2 then return matrix end
 return work.operation('local-flow-exchanges',nil,{matrix=matrix,costs=costs,locked=locked})
end
return M
