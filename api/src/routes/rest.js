import { Router } from 'express';
import { handleHead, handleGet } from './rest-query.js';
import { handlePost, handlePatch, handleDelete } from './rest-mutations.js';

const router = Router();

router.head('/:table', handleHead);
router.get('/:table', handleGet);
router.post('/:table', handlePost);
router.patch('/:table', handlePatch);
router.delete('/:table', handleDelete);

export default router;
