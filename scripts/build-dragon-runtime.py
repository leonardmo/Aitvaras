"""Build a lightweight, seated real-time asset without changing the master.

Blender --background --python scripts/build-dragon-runtime.py -- MASTER OUT
The seated pose and corrective shapes are baked once into the mesh. Only
live jaw, blink and eye-look morphs remain; no Blender rig or constraints run
in the application. Original rigged masters remain available for later clips.
"""
import bpy
import hashlib
import json
import sys
import time
from pathlib import Path

import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def coordinates(mesh):
    values = np.empty(len(mesh.vertices) * 3, dtype=np.float32)
    mesh.vertices.foreach_get('co', values)
    return values.reshape(-1, 3)


def evaluated_mesh(obj):
    bpy.context.view_layer.update()
    result = bpy.data.meshes.new_from_object(
        obj.evaluated_get(bpy.context.evaluated_depsgraph_get()),
        preserve_all_data_layers=True, depsgraph=bpy.context.evaluated_depsgraph_get())
    result.transform(obj.matrix_world)
    return result


def activate(obj):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def transfer_map(high_mesh, low_mesh):
    high_mesh.calc_loop_triangles()
    faces = np.array([tuple(tri.vertices) for tri in high_mesh.loop_triangles], dtype=np.int32)
    high = coordinates(high_mesh)
    tree = BVHTree.FromPolygons(high.tolist(), faces.tolist(), all_triangles=True)
    indices = np.empty((len(low_mesh.vertices), 3), dtype=np.int32)
    weights = np.empty((len(low_mesh.vertices), 3), dtype=np.float64)
    distances = []
    for index, vertex in enumerate(low_mesh.vertices):
        point, normal, face, distance = tree.find_nearest(vertex.co)
        if face is None:
            raise RuntimeError('Missing source surface sample')
        ids = faces[face]
        a, b, c = high[ids].astype(np.float64)
        ab, ac, ap = b - a, c - a, np.asarray(point) - a
        aa, bb, cc = ab @ ab, ab @ ac, ac @ ac
        denom = aa * cc - bb * bb
        if abs(denom) < 1e-18:
            bary = np.array([1., 0., 0.])
        else:
            v, w = ((cc * (ap @ ab) - bb * (ap @ ac)) / denom,
                    (aa * (ap @ ac) - bb * (ap @ ab)) / denom)
            bary = np.clip([1. - v - w, v, w], 0., 1.)
            bary /= bary.sum()
        indices[index], weights[index] = ids, bary
        distances.append(distance)
    return indices, weights, float(max(distances, default=0.))


args = sys.argv[sys.argv.index('--') + 1:]
source, out = [Path(value).resolve() for value in args[:2]]
out.mkdir(parents=True, exist_ok=True)
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
started = time.monotonic()
bpy.ops.wm.open_mainfile(filepath=str(source))
scene = bpy.context.scene
actors = [obj for obj in scene.objects if obj.type == 'MESH' and obj.name.startswith('Dragon.')]
for obj in actors:
    if obj.data.shape_keys:
        obj.data.shape_keys.animation_data_clear()

runtime = []
report = dict(mode='seated static body, live facial morphs', meshes=[], animations=0,
              source_sha256=source_hash, limits='No locomotion clips; original rig retained only in the master.')
body_pair = None
for original in actors:
    live = [key.name for key in original.data.shape_keys.key_blocks
            if key.name in ('jawOpen', 'eyeBlinkLeft', 'eyeBlinkRight',
                            'eyeLookLeft', 'eyeLookRight', 'eyeLookUp', 'eyeLookDown')] if original.data.shape_keys else []
    for name in live:
        original.data.shape_keys.key_blocks[name].value = 0.
    high_mesh = evaluated_mesh(original)
    high_base = coordinates(high_mesh)
    low = bpy.data.objects.new('Runtime.' + original.name, high_mesh.copy())
    scene.collection.objects.link(low)
    activate(low)
    decimate = low.modifiers.new('Runtime triangle budget', 'DECIMATE')
    decimate.ratio = .103 if original.name == 'Dragon.Body' else .40
    decimate.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=decimate.name)
    indices, weights, surface_error = transfer_map(high_mesh, low.data)
    base = coordinates(low.data)
    if live:
        low.shape_key_add(name='Basis')
    morphs = {}
    for name in live:
        key = original.data.shape_keys.key_blocks[name]
        key.value = 1.
        sampled_mesh = evaluated_mesh(original)
        delta = coordinates(sampled_mesh) - high_base
        bpy.data.meshes.remove(sampled_mesh)
        key.value = 0.
        transferred = np.einsum('nij,ni->nj', delta[indices], weights)
        target = low.shape_key_add(name=name)
        target.data.foreach_set('co', (base + transferred).astype(np.float32).ravel())
        target.value = 0.
        morphs[name] = float(np.linalg.norm(transferred, axis=1).max())
    low.data.update()
    runtime.append(low)
    report['meshes'].append(dict(name=low.name, source_triangles=sum(len(p.vertices)-2 for p in high_mesh.polygons),
                                 triangles=sum(len(p.vertices)-2 for p in low.data.polygons),
                                 vertices=len(low.data.vertices), maximum_source_surface_distance=surface_error,
                                 morph_displacements=morphs))
    if original.name == 'Dragon.Body':
        high = bpy.data.objects.new('BAKE.HighBody', high_mesh)
        scene.collection.objects.link(high)
        body_pair = high, low
    else:
        bpy.data.meshes.remove(high_mesh)
    print('RUNTIME_MESH', json.dumps(report['meshes'][-1]), flush=True)

# Preserve actual high-poly scale relief in a tangent normal map. The body
# keeps its source UV layout, so the color atlas remains registered to it.
high, low = body_pair
material = low.data.materials[0].copy()
material.name = 'Dragon.Runtime.Body'
low.data.materials[0] = material
normal = bpy.data.images.new('Dragon.Runtime.ScaleNormals', width=2048, height=2048)
normal.colorspace_settings.name = 'Non-Color'
normal.generated_color = (.5, .5, 1., 1.)
target = material.node_tree.nodes.new('ShaderNodeTexImage')
target.image = normal
material.node_tree.nodes.active = target
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 1
scene.render.threads_mode = 'FIXED'
scene.render.threads = 4
scene.render.bake.use_selected_to_active = True
scene.render.bake.cage_extrusion = .012
scene.render.bake.max_ray_distance = .035
scene.render.bake.margin = 8
for obj in scene.objects:
    obj.hide_render = obj not in (high, low)
activate(low)
high.select_set(True)
print('RUNTIME_NORMAL_BAKE_START cpu_threads=4 size=2048', flush=True)
bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT')
material.node_tree.nodes['Image Texture.002'].image = normal
normal.pack()
bpy.data.objects.remove(high, do_unlink=True)

# Reduce texture memory as well as file size. Packed images are edited only
# in this temporary Blender process, never in the editable source file.
used_images = set()
for obj in runtime:
    for mat in obj.data.materials:
        if not mat or not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type == 'TEX_IMAGE' and node.image:
                used_images.add(node.image)
report['textures'] = []
for image in used_images:
    limit = 2048 if image.name in ('Image_0', normal.name) else 1024
    width, height = image.size
    if max(width, height) > limit:
        scale = limit / max(width, height)
        image.scale(max(1, round(width * scale)), max(1, round(height * scale)))
    image.file_format = 'PNG'
    image.pack()
    report['textures'].append(dict(name=image.name, size=list(image.size)))

# Keep all runtime objects and their facial morphs; drop the authoring rig,
# cameras, stage, helper objects, actions, drivers and corrective channels.
for obj in list(bpy.data.objects):
    if obj not in runtime:
        bpy.data.objects.remove(obj, do_unlink=True)
for obj in runtime:
    obj.hide_render = False
    obj.hide_viewport = False
    obj['aitvaras_runtime'] = 'seated-v1'
    obj.select_set(True)
scene.frame_start = scene.frame_end = 1
report['triangles'] = sum(item['triangles'] for item in report['meshes'])
report['vertices'] = sum(item['vertices'] for item in report['meshes'])
assert report['triangles'] < 150000
assert all(np.isfinite(coordinates(obj.data)).all() for obj in runtime)
destination = out / 'AitvarasDragonRuntime.glb'
bpy.ops.export_scene.gltf(filepath=str(destination), export_format='GLB', use_selection=True,
                          export_animations=False, export_morph=True, export_morph_normal=False,
                          export_morph_tangent=False, export_yup=True, export_extras=True,
                          export_image_format='AUTO', export_keep_originals=False)
report['bytes'] = destination.stat().st_size
report['sha256'] = hashlib.sha256(destination.read_bytes()).hexdigest()
report['elapsed_seconds'] = round(time.monotonic()-started, 2)
report['source_unchanged'] = hashlib.sha256(source.read_bytes()).hexdigest() == source_hash
assert report['source_unchanged']
(out / 'runtime-audit.json').write_text(json.dumps(report, indent=2))
print('RUNTIME_BUILD_COMPLETE', json.dumps(report), flush=True)
