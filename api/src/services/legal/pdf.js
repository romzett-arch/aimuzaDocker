const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function renderLetter(s,registeredAt) {
  const lines=value=>escape(value).replace(/\n/g,'<br>');
  return `<!doctype html><html lang="ru"><meta charset="utf-8"><style>
  @page{size:A4;margin:22mm 20mm}body{font:12pt Arial,sans-serif;color:#172033;line-height:1.5}
  header{border-bottom:3px solid #7152d8;padding-bottom:12px;margin-bottom:20px}header strong{font-size:24pt;color:#6240b7}
  .details,footer{font-size:9pt;color:#555;white-space:pre-wrap}.recipient{text-align:right;margin:24px 0}
  h1{font-size:16pt}main{white-space:pre-wrap;overflow-wrap:anywhere}footer{border-top:1px solid #ccc;margin-top:30px;padding-top:10px}
  </style><header><strong>${escape(s.template?.header||s.organization?.name||'АИМУЗА')}</strong>
  <div class="details">${escape(s.organization?.name)}\n${escape(s.organization?.details)}</div></header>
  <div>${escape(s.number)} от ${escape(new Date(registeredAt).toLocaleDateString('ru-RU',{timeZone:'Europe/Moscow'}))}</div>
  <div class="recipient">${lines(s.recipient)}</div><h1>${escape(s.title)}</h1><main>${escape(s.body)}</main>
  ${s.files?.length?`<p>Приложения: ${s.files.map(f=>escape(f.name)).join('; ')}</p>`:''}
  <footer>${escape(s.template?.footer)}</footer></html>`;
}
export async function makePdf(s,registeredAt) {
  const form=new FormData();
  form.append('files',new Blob([renderLetter(s,registeredAt)],{type:'text/html'}),'index.html');
  const response=await fetch(`${process.env.GOTENBERG_URL||'http://gotenberg:3000'}/forms/chromium/convert/html`,{
    method:'POST',body:form,signal:AbortSignal.timeout(60000)
  });
  if(!response.ok) throw new Error('PDF_SERVICE_UNAVAILABLE');
  const buffer=Buffer.from(await response.arrayBuffer());
  if(buffer.length>25*1024*1024 || buffer.subarray(0,5).toString()!=='%PDF-') throw new Error('INVALID_PDF_RESULT');
  return buffer;
}
