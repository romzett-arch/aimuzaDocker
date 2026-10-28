export function installSafeLogging() {
  const sensitive=Object.entries(Deno.env.toObject()).filter(([key,value])=>/SECRET|PASSWORD|TOKEN|API_KEY|SERVICE_ROLE_KEY|PRIVATE_KEY/i.test(key)&&value.length>=8).map(([,value])=>value);
  const clean=(raw:string)=>{
    let value=raw.replace(/https?:\/\/[^\s"'<>]+/g,raw=>{try{const u=new URL(raw);u.username='';u.password='';u.search='';u.hash='';return u.href;}catch{return '[URL]';}})
      .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9+/=_.-]+/gi,'$1 [REDACTED]')
      .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g,'[REDACTED JWT]');
    for(const secret of sensitive) value=value.split(secret).join('[REDACTED]');
    return value;
  };
  for(const method of ['log','info','warn','error','debug'] as const) {
    const write=console[method].bind(console);
    console[method]=(...args:unknown[])=>write(...args.map(arg=>{
      if(typeof arg==='string') return clean(arg);
      if(arg instanceof Error) return clean(arg.message);
      try{return clean(JSON.stringify(arg,(key,value)=>/^(authorization|password|secret|signature|access_token|refresh_token|api_key|code)$/i.test(key)?'[REDACTED]':value));}
      catch{return '[Unserializable log value]';}
    }));
  }
}
