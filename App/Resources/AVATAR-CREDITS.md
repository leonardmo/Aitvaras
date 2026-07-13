# Avatar credit

AitvarasAvatar.glb (the optional human avatar, Setup → Avatar) originates
from the MIT-licensed TalkingHead project
(https://github.com/met4citizen/TalkingHead, avatars/brunette.glb),
a Ready Player Me-generated character with the full ARKit + Oculus
viseme blendshape set. MIT license text: see their repository.

The default character — a cute cartoon dragon — is **built procedurally**
in `App/Companion/AvatarView.swift` (`buildCartoonDragon()`): SceneKit
primitives (spheres, cones, extruded shapes) with flat cartoon shading,
a seafoam-teal body and warm orange belly, big highlighted eyes, an
openable smiling mouth, horns, ear-fins, a finned crest, small bat wings
and a curled tail. No external asset — nothing to license.
