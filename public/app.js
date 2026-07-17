const $ = id => document.getElementById(id);
let token = localStorage.getItem('gatewayAdminToken') || '';
let poll;
function toast(message){const el=$('toast');el.textContent=message;el.classList.add('show');setTimeout(()=>el.classList.remove('show'),3200)}
async function api(path, options={}){const res=await fetch(path,{...options,headers:{'content-type':'application/json','authorization':`Bearer ${token}`,...(options.headers||{})}});const data=await res.json().catch(()=>({}));if(!res.ok)throw new Error(data.error||`Request failed (${res.status})`);return data}
function displayLogin(){ $('loginCard').hidden=false;$('dashboard').hidden=true;clearInterval(poll)}
function displayDashboard(){ $('loginCard').hidden=true;$('dashboard').hidden=false;loadAll();clearInterval(poll);poll=setInterval(loadStatus,5000)}
async function loadStatus(){try{const s=await api('/admin/api/status');$('status').textContent=s.status;$('account').textContent=s.account?.wid||'Not linked';$('queued').textContent=(s.queue?.queued||0)+(s.queue?.retry||0);$('failed').textContent=s.queue?.failed||0;$('pairCard').hidden=s.ready;if(s.pairingCode){$('pairingOutput').hidden=false;$('pairingCode').textContent=s.pairingCode.match(/.{1,4}/g)?.join(' ')||s.pairingCode}else $('pairingOutput').hidden=true;if(s.qrDataUrl){$('qr').src=s.qrDataUrl;$('qr').hidden=false}else $('qr').hidden=true}catch(e){if(String(e.message).includes('Unauthorized')){localStorage.removeItem('gatewayAdminToken');token='';displayLogin()}else toast(e.message)}}
async function loadMessages(){try{const rows=await api('/admin/api/messages?limit=100');$('messages').innerHTML=rows.map(m=>`<tr><td>${new Date(m.createdAt).toLocaleString()}</td><td>${m.to.replace('@c.us','')}</td><td class="status ${m.status}">${m.status}</td><td>${m.attempts}</td><td>${escapeHtml(m.error||'')}</td><td>${m.status==='failed'?`<button class="secondary retryMessage" data-id="${m.id}">Retry</button>`:'—'}</td></tr>`).join('')}catch(e){toast(e.message)}}
function escapeHtml(v){return String(v).replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]))}
async function loadAll(){await Promise.all([loadStatus(),loadMessages()])}
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();token=$('token').value.trim();try{await api('/admin/api/status');localStorage.setItem('gatewayAdminToken',token);displayDashboard()}catch(err){toast(err.message)}})
$('logoutToken').addEventListener('click',()=>{localStorage.removeItem('gatewayAdminToken');token='';displayLogin()})
$('pairForm').addEventListener('submit',async e=>{e.preventDefault();try{const r=await api('/admin/api/pair',{method:'POST',body:JSON.stringify({phoneNumber:$('phone').value})});$('pairingOutput').hidden=false;$('pairingCode').textContent=r.pairingCode.match(/.{1,4}/g)?.join(' ')||r.pairingCode;toast('Pairing code generated')}catch(err){toast(err.message)}})
$('testForm').addEventListener('submit',async e=>{e.preventDefault();try{await api('/admin/api/test',{method:'POST',body:JSON.stringify({to:$('testTo').value,text:$('testText').value})});$('testText').value='';toast('Test message queued');loadMessages()}catch(err){toast(err.message)}})
$('refresh').addEventListener('click',loadAll)
$('unlink').addEventListener('click',async()=>{if(!confirm('Unlink WhatsApp and remove the saved session?'))return;try{await api('/admin/api/logout',{method:'POST',body:'{}'});toast('WhatsApp unlinked');loadAll()}catch(err){toast(err.message)}})
if(token)displayDashboard();else displayLogin();

$('messages').addEventListener('click',async e=>{const button=e.target.closest('.retryMessage');if(!button)return;button.disabled=true;try{await api(`/admin/api/messages/${encodeURIComponent(button.dataset.id)}/retry`,{method:'POST',body:'{}'});toast('Message returned to queue');loadAll()}catch(err){toast(err.message)}finally{button.disabled=false}})
