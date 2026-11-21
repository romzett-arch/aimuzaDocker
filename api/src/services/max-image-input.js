import { raw } from 'express';

const limit = 5 * 1024 * 1024;
const readRaw = raw({ type: 'multipart/form-data', limit: limit + 16_384 });

export function readMaxImageInput(req, res, next) {
  if (req.params.action !== 'start' || !req.is('multipart/form-data')) return next();
  readRaw(req, res, async error => {
    if (error) return next(error);
    try {
      const form = await new Request('http://localhost', {
        method: 'POST', headers: { 'Content-Type': req.get('content-type') }, body: req.body,
      }).formData();
      const input = JSON.parse(form.get('input'));
      const reference = form.get('reference');
      if (input?.kind !== 'image' || !(reference instanceof Blob) || !reference.size || reference.size > limit) {
        return res.status(422).json({ code: 'INVALID_REFERENCE' });
      }
      req.body = { ...input, reference };
      next();
    } catch {
      res.status(422).json({ code: 'INVALID_REFERENCE' });
    }
  });
}
