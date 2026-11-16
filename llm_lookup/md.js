// 浮窗和历史窗口共用的极简 Markdown：标题、列表、代码块、引用、粗斜体、行内代码、链接
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
// [文字](网址) 和裸网址；裸网址遇到空白、括号、反引号、全角标点、引号为止，句末的标点不算进去
const URLCH='(?:(?!&quot;)[^\\s<>()`\\u3000-\\u303f\\uff00-\\uffef])';
const LINK=new RegExp('\\[([^\\]\\n]+)\\]\\((https?://[^\\s)]+)\\)|https?://'+URLCH+'*(?:(?![.,;:!?\'*_])'+URLCH+')','g');
const inline=s=>esc(s).replace(LINK,(m,t,u)=>t?'<a href="'+u+'">'+t+'</a>':'<a href="'+m+'">'+m+'</a>')
  .replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*(.+?)\*\*/g,'<b>$1</b>').replace(/(^|[^*\w])\*(?!\s)(.+?)\*(?!\w)/g,'$1<i>$2</i>');
function md(src){
  const out=[];let list=null,code=null;
  const close=()=>{if(list){out.push('</'+list+'>');list=null}};
  for(const raw of src.split('\n')){
    if(code!==null){if(/^\s*```/.test(raw)){out.push('<pre>'+esc(code)+'</pre>');code=null}else code+=(code?'\n':'')+raw;continue}
    if(/^\s*```/.test(raw)){close();code='';continue}
    const line=raw.trimEnd();let m;
    if(!line.trim()){close();continue}
    if(m=line.match(/^#{1,6}\s+(.*)/)){close();out.push('<h4>'+inline(m[1])+'</h4>');continue}
    if(m=line.match(/^\s*[-*•]\s+(.*)/)){if(list!=='ul'){close();out.push('<ul>');list='ul'}out.push('<li>'+inline(m[1])+'</li>');continue}
    if(m=line.match(/^\s*\d+[.)]\s+(.*)/)){if(list!=='ol'){close();out.push('<ol>');list='ol'}out.push('<li>'+inline(m[1])+'</li>');continue}
    if(list&&/^\s+\S/.test(raw)){out[out.length-1]=out[out.length-1].replace(/<\/li>$/,'<br>'+inline(line.trim())+'</li>');continue}
    if(m=line.match(/^>\s?(.*)/)){close();out.push('<blockquote>'+inline(m[1])+'</blockquote>');continue}
    close();out.push('<p>'+inline(line)+'</p>');
  }
  if(code!==null)out.push('<pre>'+esc(code)+'</pre>');
  close();return out.join('');
}
