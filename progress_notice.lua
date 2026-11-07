local M={values={10,20,30,60,120}}
function M.seconds(value)
 value=tonumber(value)
 for _,v in ipairs(M.values) do if value==v then return v end end
 return 30
end
function M.index(value)
 value=M.seconds(value);for i,v in ipairs(M.values) do if v==value then return i end end
end
function M.ticks(value)return M.seconds(value)*60 end
return M
