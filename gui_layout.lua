local M={}
function M.find(root,name)
 if not root or not root.valid then return end
 if root.name==name then return root end
 for _,child in pairs(root.children or {}) do local found=M.find(child,name);if found then return found end end
end
function M.tabs(frame,player)
 local pane=frame.add{type='tabbed-pane',name='bfh_settings'}
 local result={}
 local resolution=player.display_resolution
 local height=math.max(220,math.min(400,math.floor((resolution and resolution.height or 800)/(player.display_scale or 1)-240)))
 for _,name in ipairs({'plans','equipment','connections','generation'}) do
  local tab=pane.add{type='tab',caption={'bfh.tab-'..name}}
  local content=pane.add{type='scroll-pane',name='bfh_page_'..name,direction='vertical',horizontal_scroll_policy='never',vertical_scroll_policy='auto'}
  content.style.width=550;content.style.height=height
  content.style.padding=12
  pane.add_tab(tab,content);result[name]=content
 end
 pane.selected_tab_index=1
 return result
end
function M.note(parent,key)
 local label=parent.add{type='label',caption={'bfh.'..key}}
 label.style.single_line=false;label.style.maximal_width=510
 return label
end
return M
