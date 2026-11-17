-- Exact Manhattan distance to immutable routing goals.
local M={}
function M.build(points,axis)
 if #points==0 then return end
 axis=axis or 1;local other=3-axis
 table.sort(points,function(a,b)
  if a[axis]~=b[axis] then return a[axis]<b[axis] end
  return a[other]<b[other]
 end)
 local middle=math.floor(#points/2)+1;local p=points[middle]
 local left,right={},{}
 for i=1,middle-1 do left[#left+1]=points[i] end
 for i=middle+1,#points do right[#right+1]=points[i] end
 local a,b=M.build(left,other),M.build(right,other)
 return {x=p[1],y=p[2],axis=axis,left=a,right=b,
  xmin=math.min(p[1],a and a.xmin or p[1],b and b.xmin or p[1]),
  xmax=math.max(p[1],a and a.xmax or p[1],b and b.xmax or p[1]),
  ymin=math.min(p[2],a and a.ymin or p[2],b and b.ymin or p[2]),
  ymax=math.max(p[2],a and a.ymax or p[2],b and b.ymax or p[2])}
end
local function nearest(node,x,y,best)
 if not node or best==0 then return best end
 local lower=math.max(node.xmin-x,0,x-node.xmax)+math.max(node.ymin-y,0,y-node.ymax)
 if lower>=best then return best end
 best=math.min(best,math.abs(x-node.x)+math.abs(y-node.y))
 local delta=node.axis==1 and x-node.x or y-node.y
 local near,far=node.left,node.right
 if delta>0 then near,far=far,near end
 best=nearest(near,x,y,best)
 if math.abs(delta)<best then best=nearest(far,x,y,best) end
 return best
end
function M.distance(tree,x,y) return nearest(tree,x,y,math.huge) end
return M
