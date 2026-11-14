/*
 * Unit tests for WechatStyler (Markdown to WeChat HTML converter).
 */
import { describe, it, expect } from '@ohos/hypium';
import { WechatStyler } from '../main/ets/browser/WechatStyler';

export default function wechatStylerTest() {
  describe('WechatStylerTest', () => {
    it('resolveColor_named_and_hex', 0, () => {
      expect(WechatStyler.resolveColor('blue')).assertEqual('#2b5aed');
      expect(WechatStyler.resolveColor('green')).assertEqual('#07c160');
      expect(WechatStyler.resolveColor('red')).assertEqual('#fa5151');
      expect(WechatStyler.resolveColor('orange')).assertEqual('#ff8200');
      expect(WechatStyler.resolveColor('#123456')).assertEqual('#123456');
      expect(WechatStyler.resolveColor('')).assertEqual('#2b5aed');
    });

    it('markdownToWechatHtml_headings_and_paragraphs', 0, () => {
      const md = '# 标题一\n\n## 标题二\n\n正文段落**加粗文本**与`代码片段`。';
      const html = WechatStyler.markdownToWechatHtml(md, 'blue');

      expect(html).assertContain('<h1');
      expect(html).assertContain('标题一');
      expect(html).assertContain('<h2');
      expect(html).assertContain('标题二');
      expect(html).assertContain('<strong');
      expect(html).assertContain('加粗文本');
      expect(html).assertContain('<code');
      expect(html).assertContain('代码片段');
    });

    it('markdownToWechatHtml_blockquote_and_codeblock', 0, () => {
      const md = '> 这是一段引用\n\n```typescript\nconst a = 1;\n```';
      const html = WechatStyler.markdownToWechatHtml(md, 'green');

      expect(html).assertContain('<blockquote');
      expect(html).assertContain('这是一段引用');
      expect(html).assertContain('<pre');
      expect(html).assertContain('const a = 1;');
    });

    it('markdownToWechatHtml_link_citations', 0, () => {
      const md = '点击查看[官方文档](https://developer.huawei.com)了解更多。';
      const html = WechatStyler.markdownToWechatHtml(md, 'blue');

      expect(html).assertContain('官方文档');
      expect(html).assertContain('[1]</sup>');
      expect(html).assertContain('参考链接：');
      expect(html).assertContain('https://developer.huawei.com');
    });

    it('markdownToWechatHtml_html_passthrough', 0, () => {
      const raw = '<section style="color: red;"><p>原生HTML</p></section>';
      const html = WechatStyler.markdownToWechatHtml(raw);

      expect(html).assertEqual(raw);
    });
  });
}
