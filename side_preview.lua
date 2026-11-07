local M={}
local gui=require('gui_layout')
local arrows={[0]='↑',[4]='→',[8]='↓',[12]='←'}
function M.direction(role,side)return (side+(role=='input' and 8 or 0))%16 end
function M.arrow(role,side)return arrows[M.direction(role,side)] end
function M.create(parent)
 local outer=parent.add{type='flow',name='bfh_side_preview',direction='vertical',tooltip={'bfh.side-help'}}
 local grid=outer.add{type='table',column_count=3};grid.style.horizontal_spacing=4;grid.style.vertical_spacing=4
 for row=1,3 do for col=1,3 do
  local side=row==1 and col==2 and 0 or row==2 and col==3 and 4 or row==3 and col==2 and 8 or row==2 and col==1 and 12
  if row==2 and col==2 then
   local box=grid.add{type='frame',direction='vertical'};box.style.width=180;box.style.height=80;box.style.padding=8;box.style.horizontal_align='center';box.style.vertical_align='center'
   local label=box.add{type='label',caption={'bfh.preview-factory'},style='bold_label'};label.style.single_line=false;label.style.horizontal_align='center';label.style.width=160
  else
   local cell=grid.add{type='flow',direction=(row==2 and 'vertical' or 'horizontal'),name=side and ('bfh_preview_edge_'..side) or nil}
   cell.style.width=col==2 and 180 or 120;cell.style.height=row==2 and 80 or 64
   cell.style.horizontal_align='center';cell.style.vertical_align='center'
  end
 end end
 return outer
end
function M.update(frame,s)
 local preview=gui.find(frame,'bfh_side_preview');if not preview then return end
 preview.visible=s.link_mode~='independent'
 local dimensions=({square={140,140},horizontal={180,80},vertical={100,160}})[s.layout_shape] or {180,80}
 local grid=preview.children[1]
 for i,cell in ipairs(grid.children) do
  local row,col=math.floor((i-1)/3)+1,(i-1)%3+1
  cell.style.width=col==2 and dimensions[1] or 120
  cell.style.height=row==2 and dimensions[2] or 64
 end
 grid.children[5].children[1].style.width=dimensions[1]-16
 for _,side in ipairs({0,4,8,12}) do
  local cell=gui.find(preview,'bfh_preview_edge_'..side);cell.clear()
  for _,role in ipairs({'input','output'}) do
   if (s[role..'_side'] or (role=='input' and 12 or 4))==side then
    local direction=M.direction(role,side)
    local arrow=cell.add{type='frame',name='bfh_preview_'..role,style='bfh_preview_'..role..'_'..direction,direction='vertical'}
    local label=arrow.add{type='label',caption={'bfh.preview-'..role},style='bold_label'}
    label.style.font_color={r=.08,g=.12,b=.10};label.style.horizontal_align='center';label.style.width=(direction==0 or direction==8) and 72 or 108
   end
  end
 end
end
return M
