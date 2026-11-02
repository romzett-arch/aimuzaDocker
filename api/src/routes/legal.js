import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { appointments } from './legal-appointments.js';
import { workspace } from './legal-workspace.js';
import { documents } from './legal-documents.js';
import { files } from './legal-files.js';
import { imports } from './legal-import.js';
import { createUploadBudget } from '../security/upload-budget.js';

const router=Router();
router.use(rateLimit({windowMs:60000,limit:180,standardHeaders:true,legacyHeaders:false}));
router.use((_req,res,next)=>{res.set('Cache-Control','private, no-store');next();});
const uploadBudget=createUploadBudget(2);
router.use((req,res,next)=>req.method==='POST'&&(req.path==='/documents/import'||/^\/documents\/[a-f0-9-]+\/files$/i.test(req.path))?uploadBudget(req,res,next):next());
appointments(router);workspace(router);imports(router);documents(router);files(router);
export default router;
