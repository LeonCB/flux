const canvas = document.querySelector('#light');
const ctx = canvas.getContext('2d');
const colors = {Aurora:['#51dbba','#9171ec','#ee85ba'],Original:['#8b98f0','#dd8ab2','#e8ba7f'],Plasma:['#f05f41','#efa242','#973c6a'],Poolside:['#529fcc','#99d8e8','#69d8ca'],Freedom:['#0057b7','#167dd9','#ffd700']};
let palette='Aurora', time=0, previous=0, raf=0, width=600, height=540;
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
let paused = reduced.matches;
// A regular field of short, tapered trails echoes Flux's line renderer.
// Spatial color interpolation keeps neighboring lines in the same color band.
const ramps = Object.fromEntries(Object.entries(colors).map(([name, stops]) => [name,
 stops.map(hex => [1,3,5].map(offset => parseInt(hex.slice(offset,offset+2),16)))
]));
function tint(position) {
 const ramp = ramps[palette];
 const value = ((position % 1) + 1) % 1 * ramp.length;
 const index = Math.floor(value), blend = value-index;
 return ramp[index].map((channel,i) => Math.round(channel*(1-blend)+ramp[(index+1)%ramp.length][i]*blend));
}
function render(){
 ctx.globalAlpha=1;
 ctx.fillStyle='#020305';ctx.fillRect(0,0,width,height);
 const scale=Math.min(width,height);
 const spacing=Math.max(10,scale/43);
 const drift=time*.09;
 const vortices=[
  [.27+.035*Math.sin(drift),.37,-.14],
  [.76,.68+.035*Math.cos(drift),.16],
  [.78,.03,-.08]
 ];
 ctx.lineCap='round';
 for(let row=-2;row<height/spacing+2;row++){
  for(let col=-2;col<width/spacing+2;col++){
   const x=(col+.5*(row%2))*spacing;
   const y=row*spacing;
   const nx=x/width,ny=y/height;
   let vx=.28+.18*Math.sin(ny*6+drift),vy=-.12+.16*Math.sin(nx*6-drift);
   for(const [cx,cy,strength] of vortices){
    const dx=(nx-cx)*width/scale,dy=(ny-cy)*height/scale;
    const influence=strength/(dx*dx+dy*dy+.016);
    vx-=dy*influence;vy+=dx*influence;
   }
   const magnitude=Math.hypot(vx,vy);
   const angle=Math.atan2(vy,vx);
   const band=.5+.5*Math.sin(nx*5+ny*6+Math.sin(nx*4-ny*3)-drift);
   const shimmer=.85+.15*Math.sin(col*1.7+row*2.3+time*.6);
   const strength=Math.min(1,magnitude*1.65)*(.35+.65*band)*shimmer;
   const length=spacing*(.55+1.5*Math.min(1,magnitude));
   const dx=Math.cos(angle)*length,dy=Math.sin(angle)*length;
   const rgb=tint(nx*.48+ny*.32+band*.25+drift*.08);
   const gradient=ctx.createLinearGradient(x-dx*.5,y-dy*.5,x+dx*.5,y+dy*.5);
   gradient.addColorStop(0,`rgba(${rgb},${strength*.05})`);
   gradient.addColorStop(.7,`rgba(${rgb},${strength*.95})`);
   gradient.addColorStop(1,`rgba(${rgb.map(c=>Math.round(c+(255-c)*.38))},${strength})`);
   ctx.strokeStyle=gradient;
   ctx.lineWidth=spacing*(.14+.15*strength);
   ctx.beginPath();ctx.moveTo(x-dx*.5,y-dy*.5);
   ctx.quadraticCurveTo(x-dy*.055,y+dx*.055,x+dx*.5,y+dy*.5);ctx.stroke();
  }
 }
}
function resize(){const rect=canvas.getBoundingClientRect();width=rect.width;height=rect.height;const dpr=Math.min(devicePixelRatio||1,2);canvas.width=Math.round(width*dpr);canvas.height=Math.round(height*dpr);ctx.setTransform(dpr,0,0,dpr,0,0);render();}
function tick(timestamp){raf=0;if(paused||document.hidden)return;time+=Math.min((timestamp-previous)/1000,.05);previous=timestamp;render();raf=requestAnimationFrame(tick);}
function animate(){cancelAnimationFrame(raf);raf=0;previous=performance.now();if(!paused&&!document.hidden)raf=requestAnimationFrame(tick);}
const motion=document.querySelector('#motion');function updateMotion(){motion.textContent=paused?'Play animation':'Pause animation';motion.setAttribute('aria-pressed',String(paused));animate();}
motion.addEventListener('click',()=>{paused=!paused;updateMotion();});
reduced.addEventListener('change',()=>{paused=reduced.matches;updateMotion();});
document.addEventListener('visibilitychange',animate);
document.querySelectorAll('[data-palette]').forEach(button=>button.addEventListener('click',()=>{palette=button.dataset.palette;document.querySelectorAll('[data-palette]').forEach(b=>{const selected=b===button;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});document.querySelector('#palette-name').textContent=`${String(Object.keys(colors).indexOf(palette)+1).padStart(2,'0')} / ${palette.toUpperCase()}`;render();}));
const clock=document.querySelector('#clock');function updateClock(){clock.textContent=new Intl.DateTimeFormat(undefined,{hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(new Date());}
document.querySelector('#clock-toggle').addEventListener('change',event=>{clock.hidden=!event.target.checked;updateClock();});
setInterval(updateClock,1000);new ResizeObserver(resize).observe(canvas);resize();updateMotion();
