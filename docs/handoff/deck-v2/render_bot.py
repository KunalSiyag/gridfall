import bpy, math, sys, os
out=sys.argv[sys.argv.index('--')+1]
glb=sys.argv[sys.argv.index('--')+2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
objs=[o for o in bpy.context.scene.objects if o.type=='MESH']
import mathutils
mn=mathutils.Vector((1e9,)*3); mx=mathutils.Vector((-1e9,)*3)
for o in objs:
    for c in o.bound_box:
        w=o.matrix_world@mathutils.Vector(c)
        mn=mathutils.Vector((min(mn[i],w[i]) for i in range(3))); mx=mathutils.Vector((max(mx[i],w[i]) for i in range(3)))
ctr=(mn+mx)/2; size=max((mx-mn))
sc=bpy.context.scene
w=bpy.data.worlds.new('w'); sc.world=w; w.use_nodes=True
bg=w.node_tree.nodes['Background']; bg.inputs[0].default_value=(0.012,0.02,0.05,1); bg.inputs[1].default_value=1.0
def light(name,loc,energy,kind='AREA',size_=4):
    l=bpy.data.lights.new(name,kind); l.energy=energy
    if kind=='AREA': l.size=size_
    o=bpy.data.objects.new(name,l); sc.collection.objects.link(o); o.location=loc
    d=(ctr-mathutils.Vector(loc)); o.rotation_euler=d.to_track_quat('-Z','Y').to_euler()
K=130*size*size
light('key',(ctr.x+size*1.5,ctr.y-size*2,ctr.z+size*1.5),K,'AREA',size*1.2)
light('fill',(ctr.x-size*2,ctr.y-size*1.2,ctr.z+size*0.4),K*0.35,'AREA',size*1.5)
light('rim',(ctr.x,ctr.y+size*2,ctr.z+size),K*0.6,'AREA',size)
cam=bpy.data.cameras.new('c'); cam.lens=60
co=bpy.data.objects.new('c',cam); sc.collection.objects.link(co); sc.camera=co
co.location=(ctr.x+size*0.9,ctr.y-size*2.3,ctr.z+size*0.55)
co.rotation_euler=(ctr-co.location).to_track_quat('-Z','Y').to_euler()
sc.render.resolution_x=900; sc.render.resolution_y=900
for eng in ('BLENDER_EEVEE_NEXT','BLENDER_EEVEE','BLENDER_WORKBENCH'):
    try: sc.render.engine=eng; break
    except TypeError: pass
print('engine',sc.render.engine)
sc.render.filepath=out; bpy.ops.render.render(write_still=True)
