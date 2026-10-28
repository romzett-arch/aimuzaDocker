// A process-wide bound applies before express.raw/multer allocate file buffers.
export function createUploadBudget(maxActive=2) {
  let active=0;
  const users=new Set();
  return (req,res,next)=>{
    if(!['POST','PUT'].includes(req.method) || /\/(sign|public-url)\//.test(req.path)) return next();
    const user=req.user?.id;
    if(!user) return res.status(401).json({error:'Authentication required'});
    if(active>=maxActive || users.has(user)) {
      res.set('Retry-After','5');return res.status(429).json({error:'Upload capacity reached'});
    }
    if(Number(req.headers['content-length'])>100*1024*1024) return res.status(413).json({error:'File size limit exceeded'});
    active++;users.add(user);let released=false;
    const release=()=>{if(!released){released=true;active--;users.delete(user);}};
    res.once('finish',release);res.once('close',release);req.once('aborted',release);
    next();
  };
}
