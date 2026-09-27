"""Sample source texture ink at a front ray hit, for local lip occlusion tests."""
import numpy as np
from mathutils import Vector

class SourceInk:
    def __init__(self,body,bvh):
        self.bvh=bvh;mesh=body.data;mesh.calc_loop_triangles()
        self.triangles=list(mesh.loop_triangles)
        self.positions=np.asarray([v.co for v in mesh.vertices])
        self.uv=np.asarray([p.uv for p in mesh.uv_layers[0].data])
        image=next(n.image for n in mesh.materials[0].node_tree.nodes if n.type=='TEX_IMAGE' and n.image and 'BaseColor' in n.image.filepath)
        self.width,self.height=image.size
        pixels=np.empty(self.width*self.height*4,np.float32);image.pixels.foreach_get(pixels)
        self.pixels=pixels.reshape(self.height,self.width,4)

    def sample(self,x,z):
        hit,_,index,_=self.bvh.ray_cast(Vector((x,-1,z)),Vector((0,1,0)))
        if hit is None:raise ValueError('Source ink ray misses head')
        tri=self.triangles[index];a,b,c=self.positions[list(tri.vertices)]
        v0,v1,v2=b-a,c-a,np.asarray(hit)-a
        d00,d01,d11=np.dot(v0,v0),np.dot(v0,v1),np.dot(v1,v1)
        d20,d21=np.dot(v2,v0),np.dot(v2,v1);den=d00*d11-d01*d01
        wb=(d11*d20-d01*d21)/den;wc=(d00*d21-d01*d20)/den
        uv=self.uv[list(tri.loops)]
        u,v=uv[0]*(1-wb-wc)+uv[1]*wb+uv[2]*wc
        color=self.pixels[min(self.height-1,max(0,int(v*self.height))),min(self.width-1,max(0,int(u*self.width))),:3]
        return hit.y,bool(color.max()<.12)
