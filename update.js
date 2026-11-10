/* Lagebild: Hinweis auf eine neue App-Version.
   Läuft in jeder Seite, sobald sie in der Lagebild-App geöffnet ist. Vergleicht die installierte Build-Nummer mit dem
   neuesten erfolgreichen App-Bau auf GitHub und zeigt oben einen Hinweis – auch wenn die App nur aus dem Hintergrund
   zurückkommt und unabhängig davon, ob AltServer läuft. (Nur das Installieren selbst braucht AltStore + AltServer.) */
(function(){'use strict';
  var N=window.LagebildNative;if(!N||!N.caps||!N.caps.build)return;
  var API='https://api.github.com/repos/BSSRAGU/lagebild/actions/workflows/ios-build.yml/runs?status=success&per_page=1';
  var IPA='https://github.com/BSSRAGU/lagebild/releases/download/app-latest/Lagebild.ipa';
  var lastCheck=0;
  function get(k){try{return sessionStorage.getItem(k)}catch(e){return null}}
  function set(k,v){try{sessionStorage.setItem(k,v)}catch(e){}}
  function show(latest){
    var old=document.getElementById('lbUpd');if(old){if(old.getAttribute('data-b')===String(latest))return;old.remove()}
    if(get('lb.upd.later')===String(latest))return;
    var d=document.createElement('div');d.id='lbUpd';d.setAttribute('role','alert');d.setAttribute('data-b',String(latest));
    d.style.cssText='position:fixed;left:8px;right:8px;top:calc(env(safe-area-inset-top,0px) + 8px);z-index:99999;background:#1B2A40;border:2px solid #FFB020;border-radius:16px;padding:12px 14px;color:#F3EFE7;font:16px/1.35 -apple-system,system-ui,sans-serif;box-shadow:0 8px 30px rgba(0,0,0,.6)';
    var t=document.createElement('div');t.style.cssText='font-weight:700;font-size:18px;color:#FFE2A6';t.textContent='Neue App-Version: Build '+latest;
    var s=document.createElement('div');s.style.cssText='font-size:14px;color:#B9C6D8;margin-top:2px';
    s.textContent='Installiert ist Build '+N.caps.build+'. Zum Installieren muss AltServer am PC laufen (gleiches WLAN oder Kabel).';
    var row=document.createElement('div');row.style.cssText='display:flex;gap:8px;margin-top:10px;flex-wrap:wrap';
    function btn(label,primary,fn){var b=document.createElement('button');b.type='button';b.textContent=label;
      b.style.cssText='flex:1;min-height:46px;border-radius:12px;font:600 16px -apple-system,system-ui,sans-serif;padding:0 10px;'+(primary?'border:0;background:#FFB020;color:#1A1200':'border:1px solid rgba(120,150,190,.4);background:rgba(33,48,70,.9);color:#F3EFE7');
      b.onclick=fn;row.appendChild(b)}
    btn('Aktualisieren',true,function(){location.href='altstore://install?url='+encodeURIComponent(IPA)});
    btn('Datei laden',false,function(){location.href=IPA});
    btn('Später',false,function(){set('lb.upd.later',String(latest));d.remove()});
    d.appendChild(t);d.appendChild(s);d.appendChild(row);(document.body||document.documentElement).appendChild(d)}
  function check(){var now=Date.now();if(now-lastCheck<10*60000)return;lastCheck=now;
    fetch(API,{cache:'no-store',headers:{'Accept':'application/vnd.github+json'}}).then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r.json()})
      .then(function(j){var run=j&&j.workflow_runs&&j.workflow_runs[0];var latest=run?Number(run.run_number):0;window.__lbLatestBuild=latest;if(latest>Number(N.caps.build))show(latest)})
      .catch(function(){lastCheck=now-9*60000})}// Fehler: in einer Minute erneut versuchen
  check();
  document.addEventListener('visibilitychange',function(){if(!document.hidden)check()});
  window.addEventListener('pageshow',check);
  setInterval(function(){if(!document.hidden)check()},60000);
})();
