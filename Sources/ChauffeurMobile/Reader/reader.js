(function () {
  'use strict';

  var md = window.markdownit({ html: false, linkify: true, typographer: false });

  // Task lists: "[ ]" / "[x]" at the start of a list item's first paragraph.
  md.core.ruler.after('inline', 'task_lists', function (state) {
    var tokens = state.tokens;
    for (var i = 2; i < tokens.length; i++) {
      var tok = tokens[i];
      if (tok.type !== 'inline' ||
          tokens[i - 1].type !== 'paragraph_open' ||
          tokens[i - 2].type !== 'list_item_open') {
        continue;
      }
      var match = /^\[([ xX])\](?:\s+|$)/.exec(tok.content);
      if (!match || !tok.children || !tok.children.length) continue;
      var first = tok.children[0];
      if (first.type !== 'text') continue;
      var textMatch = /^\[([ xX])\](?:\s+|$)/.exec(first.content);
      if (!textMatch) continue;
      first.content = first.content.slice(textMatch[0].length);
      tok.content = tok.content.slice(match[0].length);
      var box = new state.Token('html_inline', '', 0);
      box.content = '<input type="checkbox" disabled' + (match[1] === ' ' ? '' : ' checked') + '> ';
      tok.children.unshift(box);
      tokens[i - 2].attrJoin('class', 'task-list-item');
    }
  });

  // GitHub-style heading ids, de-duplicated per render.
  function slugify(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, '')
      .replace(/\s/g, '-');
  }

  md.renderer.rules.heading_open = function (tokens, idx, options, env, self) {
    var token = tokens[idx];
    var inline = tokens[idx + 1];
    if (inline && inline.type === 'inline') {
      var text = (inline.children || [])
        .filter(function (c) { return c.type === 'text' || c.type === 'code_inline'; })
        .map(function (c) { return c.content; })
        .join('');
      var base = slugify(text);
      var slugs = env.slugs || (env.slugs = {});
      var slug = base;
      if (Object.prototype.hasOwnProperty.call(slugs, base)) {
        slugs[base] += 1;
        slug = base + '-' + slugs[base];
      } else {
        slugs[base] = 0;
      }
      token.attrSet('id', slug);
    }
    return self.renderToken(tokens, idx, options);
  };

  // Route every non-fragment link through the native handler.
  var defaultLinkOpen = md.renderer.rules.link_open || function (tokens, idx, options, env, self) {
    return self.renderToken(tokens, idx, options);
  };
  md.renderer.rules.link_open = function (tokens, idx, options, env, self) {
    var token = tokens[idx];
    var hrefIndex = token.attrIndex('href');
    if (hrefIndex >= 0) {
      var href = token.attrs[hrefIndex][1];
      if (href.charAt(0) !== '#') {
        token.attrs[hrefIndex][1] = 'chauffeur-reader://link/?to=' + encodeURIComponent(href);
      }
    }
    return defaultLinkOpen(tokens, idx, options, env, self);
  };

  md.renderer.rules.table_open = function (tokens, idx, options, env, self) {
    return '<div class="table-scroll">' + self.renderToken(tokens, idx, options);
  };
  md.renderer.rules.table_close = function (tokens, idx, options, env, self) {
    return self.renderToken(tokens, idx, options) + '</div>';
  };

  function scrollToHash() {
    if (!location.hash || location.hash.length < 2) return;
    var id = location.hash.slice(1);
    try { id = decodeURIComponent(id); } catch (e) { /* keep raw */ }
    var target = document.getElementById(id);
    if (target) target.scrollIntoView();
  }

  // Only the first render follows the fragment; live updates keep the reader's scroll position.
  var hasRendered = false;

  function rerender() {
    return fetch('document.md', { cache: 'no-store' })
      .then(function (response) { return response.text(); })
      .then(function (text) {
        document.getElementById('doc').innerHTML = md.render(text, { slugs: {} });
        if (!hasRendered) {
          hasRendered = true;
          scrollToHash();
        }
      });
  }

  window.chauffeurReader = { rerender: rerender };
  document.addEventListener('DOMContentLoaded', function () { rerender(); });
})();
