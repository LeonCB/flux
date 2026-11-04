import { writeFileSync } from 'node:fs';

// Static companion to the website's Aurora flow illustration.
const paths = [];
for (let y = -12; y < 432; y += 12) {
  for (let x = 460; x < 1240; x += 12) {
    const nx = (x - 460) / 780, ny = y / 420;
    let vx = .28 + .18 * Math.sin(ny * 6), vy = -.12 + .16 * Math.sin(nx * 6);
    for (const [cx, cy, strength] of [[.27,.37,-.14],[.76,.715,.16],[.78,.03,-.08]]) {
      const dx = (nx-cx)*780/420, dy = ny-cy;
      const influence = strength/(dx*dx+dy*dy+.016);
      vx -= dy*influence; vy += dx*influence;
    }
    const magnitude = Math.hypot(vx,vy), angle = Math.atan2(vy,vx);
    const band = .5+.5*Math.sin(nx*5+ny*6+Math.sin(nx*4-ny*3));
    const alpha = Math.min(1,magnitude*1.65)*(.35+.65*band);
    const length = 12*(.55+1.5*Math.min(1,magnitude));
    const dx = Math.cos(angle)*length, dy = Math.sin(angle)*length;
    paths.push(`<path d="M${(x-dx/2).toFixed(1)} ${(y-dy/2).toFixed(1)}q${(dx/2-dy*.055).toFixed(1)} ${(dy/2+dx*.055).toFixed(1)} ${dx.toFixed(1)} ${dy.toFixed(1)}" opacity="${alpha.toFixed(2)}"/>`);
  }
}
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="420" viewBox="0 0 1200 420" role="img" aria-labelledby="title desc">
<title id="title">Flux — a little light, while you're away.</title>
<desc id="desc">Flux Windows screensaver. Short teal, violet, and pink light trails form flowing Aurora vortices on black.</desc>
<defs><linearGradient id="aurora" gradientUnits="userSpaceOnUse" x1="460" y1="0" x2="1200" y2="420"><stop stop-color="#9171ec"/><stop offset=".5" stop-color="#ee85ba"/><stop offset="1" stop-color="#51dbba"/></linearGradient><linearGradient id="fade"><stop offset=".36" stop-color="white"/><stop offset=".54" stop-color="black"/></linearGradient><clipPath id="clip"><rect width="1200" height="420" rx="24"/></clipPath><mask id="textFade"><rect width="1200" height="420" fill="url(#fade)"/></mask></defs>
<g clip-path="url(#clip)"><rect width="1200" height="420" fill="#080b10"/>
<g fill="none" stroke="url(#aurora)" stroke-width="2.7" stroke-linecap="round">${paths.join('')}</g>
<rect width="1200" height="420" fill="#080b10" mask="url(#textFade)"/>
<g font-family="Segoe UI,Arial,sans-serif"><text x="64" y="79" fill="#b2efd9" font-size="13" letter-spacing="3">WINDOWS · OPEN SOURCE</text><text x="60" y="197" fill="#f2f5f7" font-size="94" font-weight="600" letter-spacing="-5">flux</text><text x="64" y="253" fill="#b2efd9" font-size="26">A little light, while you're away.</text><text x="64" y="338" fill="#99a6b3" font-size="16">Five palettes. Every display. Time, if you want it.</text></g></g></svg>\n`;
writeFileSync(new URL('../docs/flux-banner.svg', import.meta.url), svg);
