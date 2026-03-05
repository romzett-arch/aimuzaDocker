const r = await fetch("http://ffmpeg-api:3001/health");
console.log("Status:", r.status, "Body:", await r.text());
