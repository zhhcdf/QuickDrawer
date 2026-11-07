import io

# 1) App.xaml 补 NoteBodyMaxHeight
p = r'src/QuickDrawer/App.xaml'
s = io.open(p, encoding='utf-8-sig').read()
bom = s.startswith('\ufeff')
if bom: s = s[1:]

old = '''        <sys:Double x:Key="NoteBodyLineHeight">20</sys:Double>'''
new = '''        <sys:Double x:Key="NoteBodyLineHeight">20</sys:Double>
        <sys:Double x:Key="NoteBodyMaxHeight">150</sys:Double>'''
assert s.count(old) == 1, ('app', s.count(old))
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8-sig' if bom else 'utf-8', newline='').write(s)
print('App.xaml maxheight ok, bom =', bom)

# 2) DrawerWindow.xaml: 两处 MaxHeight="150" 改资源
p = r'src/QuickDrawer/DrawerWindow.xaml'
s = io.open(p, encoding='utf-8-sig').read()
bom = s.startswith('\ufeff')
if bom: s = s[1:]

old = '''                                                               MinHeight="34" MaxHeight="150"
                                                               TextTrimming="CharacterEllipsis"'''
new = '''                                                               MinHeight="34"
                                                               MaxHeight="{DynamicResource NoteBodyMaxHeight}"
                                                               TextTrimming="CharacterEllipsis"'''
assert s.count(old) == 1, ('tb', s.count(old))
s = s.replace(old, new)

old = '''                                                             MinHeight="34" MaxHeight="150"
                                                             VerticalScrollBarVisibility="Auto"'''
new = '''                                                             MinHeight="34"
                                                             MaxHeight="{DynamicResource NoteBodyMaxHeight}"
                                                             VerticalScrollBarVisibility="Auto"'''
assert s.count(old) == 1, ('edit', s.count(old))
s = s.replace(old, new)

io.open(p, 'w', encoding='utf-8-sig' if bom else 'utf-8', newline='').write(s)
print('DrawerWindow.xaml maxheight ok, bom =', bom)
