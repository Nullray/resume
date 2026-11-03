const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const checkOnly = args.includes('--check-only');
const outputFlag = args.indexOf('--output-dir');
if (outputFlag !== -1 && !args[outputFlag + 1]) {
  throw new Error('--output-dir requires a directory.');
}
const output = outputFlag === -1
  ? path.join(root, 'pdf')
  : path.resolve(args[outputFlag + 1]);
const variants = [
  { id: 'admin', name: '行政科研综合版' },
  { id: 'marketing', name: '活动营销综合版' },
];

async function main() {
  const options = { headless: true };
  if (process.env.CHROME_EXECUTABLE) {
    options.executablePath = process.env.CHROME_EXECUTABLE;
  }
  const browser = await chromium.launch(options);
  try {
    const source = await browser.newPage({ viewport: { width: 1460, height: 1600 } });
    await source.goto(pathToFileURL(path.join(root, 'resume.html')).href);
    await source.evaluate(() => document.fonts.ready);
    const css = await source.locator('style').evaluateAll(
      elements => elements.map(element => element.textContent).join('\n')
    );
    const report = [];
    if (!checkOnly) fs.mkdirSync(output, { recursive: true });

    for (const variant of variants) {
      await source.locator(`.tab[data-id="${variant.id}"]`).click();
      const data = await source.locator(`#doc-${variant.id} .paper`).evaluate(element => {
        const clone = element.cloneNode(true);
        clone.removeAttribute('style');
        clone.querySelectorAll('[contenteditable]').forEach(node => {
          node.removeAttribute('contenteditable');
        });
        return { html: clone.outerHTML, text: element.innerText };
      });
      const page = await browser.newPage({ viewport: { width: 794, height: 1123 } });
      const printCss = `
        @page { size: A4; margin: 0; }
        html, body { margin: 0 !important; padding: 0 !important; background: white !important; }
        .paper { margin: 0 !important; transform: none !important; box-shadow: none !important; }
      `;
      await page.setContent(`<!doctype html><html lang="zh-CN"><head>
        <meta charset="utf-8"><title>孙维 - ${variant.name}</title>
        <style>${css}</style><style>${printCss}</style></head>
        <body>${data.html}</body></html>`);
      await page.evaluate(() => document.fonts.ready);
      const layout = await page.locator('.paper').evaluate(element => {
        const paper = element.getBoundingClientRect();
        const content = element.querySelector('.resume-content').getBoundingClientRect();
        const roleRows = [...element.querySelectorAll('.entry > .entry-head')].map(row => {
          const bounds = row.getBoundingClientRect();
          const title = row.querySelector('.entry-title').getBoundingClientRect();
          const role = row.querySelector('.role').getBoundingClientRect();
          const date = row.querySelector('time').getBoundingClientRect();
          return {
            centerError: Math.abs((role.left + role.right - bounds.left - bounds.right) / 2),
            overlap: title.right > role.left + 1 || role.right > date.left + 1,
          };
        });
        return {
          width: paper.width,
          height: paper.height,
          bottomMargin: paper.bottom - content.bottom,
          rolesAligned: roleRows.every(row => row.centerError < 1 && !row.overlap),
          naturalWrapping: [...element.querySelectorAll('.detail')].every(
            node => getComputedStyle(node).textWrap === 'wrap'
          ),
        };
      });
      if (Math.abs(layout.width - 210 * 96 / 25.4) > 1 ||
          Math.abs(layout.height - 297 * 96 / 25.4) > 1 ||
          layout.bottomMargin < 22 || !layout.rolesAligned || !layout.naturalWrapping) {
        throw new Error(`${variant.name}: layout validation failed: ${JSON.stringify(layout)}`);
      }
      const pdfName = `孙维_${variant.name}.pdf`;
      if (!checkOnly) {
        await page.emulateMedia({ media: 'print' });
        await page.pdf({
          path: path.join(output, pdfName),
          format: 'A4', preferCSSPageSize: true, printBackground: true,
          displayHeaderFooter: false, tagged: true,
          margin: { top: '0', bottom: '0', left: '0', right: '0' },
        });
      }
      report.push({ name: variant.name, pdfName, text: data.text, layout });
      console.log(`${variant.name}: A4 layout passed; bottom margin ${layout.bottomMargin.toFixed(1)}px`);
      await page.close();
    }
    if (!checkOnly) {
      fs.writeFileSync(path.join(output, 'layout-report.json'), JSON.stringify(report, null, 2));
    }
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
