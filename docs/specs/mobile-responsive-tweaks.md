# Feature Spec: Mobile-Responsive Tweaks

**Status:** Implemented  
**Date:** 2026-04-26  
**Strategy:** Preserve Density via Overflow — no new mobile-only components; all changes are additive CSS/SCSS

---

## 1. Background

The app was designed for desktop density. On narrow viewports (< 640 px) three pain points emerge:

1. The market-index top bar clips and shows an incomplete/empty strip because `overflow: hidden` was set on the host.
2. The Holdings and Ledger tables could truncate or wrap on small screens, losing column context.
3. No shared SCSS breakpoint tokens existed — every component duplicated raw pixel values.

---

## 2. Goals

- Unify breakpoint constants into a single SCSS partial (`src/styles/_breakpoints.scss`).
- Allow the market-index bar to scroll horizontally while hiding scrollbar chrome.
- Allow Holdings and Ledger tables to scroll horizontally while pinning the first (context) column.
- Preserve all existing desktop behaviour — zero visual change on viewports ≥ 1024 px.

## Non-Goals

- No layout reflow (no stacking, no column hiding, no hamburger menus).
- No new components or Angular change-detection changes.
- No TypeScript or HTML template changes.

---

## 3. Prerequisite: Viewport Meta

**File:** `src/index.html`

Confirmed at line 7:

```html
<meta name="viewport" content="width=device-width, initial-scale=1">
```

Already correct — no edit required.

---

## 4. SCSS Breakpoint Tokens

### 4.1 New file: `src/styles/_breakpoints.scss`

```scss
$breakpoint-xs: 480px;   // small phones (portrait)
$breakpoint-sm: 640px;   // large phones / small tablets
$breakpoint-md: 768px;   // tablets
$breakpoint-lg: 1024px;  // small desktops / landscape tablets
$breakpoint-xl: 1280px;  // standard desktop
```

### 4.2 `angular.json` — `stylePreprocessorOptions`

Added to both `build.options` and `test.options`:

```json
"stylePreprocessorOptions": {
  "includePaths": ["src/styles"]
}
```

This lets any component SCSS do `@use 'breakpoints' as bp` without relative paths.

### 4.3 Usage pattern

```scss
@use 'breakpoints' as bp;

@media (max-width: bp.$breakpoint-md) { ... }
```

> **Migration note:** Existing hardcoded `px` values in other components are out of scope. New and changed rules in this spec use tokens; legacy rules may be migrated opportunistically.

---

## 5. Market-Index Top Bar

**Files changed:**
- `src/app/shared/market-indexes/market-indexes.component.scss`
- `src/app/app.component.scss`

### Problem

`:host` had `overflow: hidden`, clipping index cards on narrow screens and blocking touch-scroll.

### Changes — `market-indexes.component.scss`

Replaced `overflow: hidden` on `:host` with:

```scss
overflow-x: auto;
overflow-y: hidden;
-webkit-overflow-scrolling: touch;
scrollbar-width: none;
-ms-overflow-style: none;
&::-webkit-scrollbar { display: none; }
```

Changed `.ticker-static` to use `min-width: max-content` (removed `flex: 1` / `min-width: 0` / `justify-content: space-between`) so the strip can be wider than the viewport and trigger scroll.

### Changes — `app.component.scss`

- Added `@use 'breakpoints' as bp` at file top.
- Migrated `@media (max-width: 768px)` → `@media (max-width: bp.$breakpoint-md)`.

---

## 6. Holdings Table — Horizontal Scroll + Sticky First Column

**File changed:** `src/app/portfolio/portfolio.component.scss`

### Changes

`.table-container` already had `overflow-x: auto`. Added thin scrollbar styling (matches app-wide pattern from `buy-below.component.scss`):

```scss
scrollbar-width: thin;
scrollbar-color: rgba(255, 255, 255, 0.15) transparent;
&::-webkit-scrollbar { height: 6px; }
&::-webkit-scrollbar-track { background: transparent; }
&::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.15); border-radius: 3px; }
```

Inside `.holdings-table`, pinned the first column (Ticker):

```scss
thead tr th:first-child,
tbody tr td:first-child {
  position: sticky;
  left: 0;
  z-index: 10;
  background: var(--bg-primary); // table rows are transparent; page bg prevents bleed-through
}
thead tr th:first-child { z-index: 20; }
```

---

## 7. Ledger (Transaction History) Table — Horizontal Scroll + Sticky First Column

**File changed:** `src/app/transaction-history/transaction-history.component.scss`

### Changes

`.txn-history__table-wrap` already had `overflow-x: auto`. Added matching thin scrollbar.

Inside `.txn-history__table`, pinned the first column (Date):

```scss
thead tr th:first-child,
tbody tr td:first-child {
  position: sticky;
  left: 0;
  z-index: 10;
  background: var(--bg-secondary); // matches .txn-history wrapper background
}
thead tr th:first-child { z-index: 20; }
```

---

## 8. SCSS Constraints

| Rule | Applied |
|------|---------|
| All new `@media` queries use tokens from `_breakpoints.scss` | ✅ |
| Sticky cell backgrounds use CSS custom properties (`var(--bg-primary)`, `var(--bg-secondary)`) | ✅ |
| Scrollbar sizing (6 px height, 3 px radius) matches existing components | ✅ |
| `rgba()` for scrollbar colour — no opaque hex | ✅ |
| No new BEM blocks — extended existing selectors | ✅ |

---

## 9. Files Changed

| File | Change |
|------|--------|
| `src/index.html` | Verified only — no edit |
| `src/styles/_breakpoints.scss` | **New** — SCSS breakpoint token definitions |
| `angular.json` | Added `stylePreprocessorOptions.includePaths` to `build` and `test` targets |
| `src/app/shared/market-indexes/market-indexes.component.scss` | Scroll + scrollbar-hide on `:host`; `min-width: max-content` on `.ticker-static` |
| `src/app/app.component.scss` | `@use 'breakpoints'`; `768px` → `bp.$breakpoint-md` |
| `src/app/portfolio/portfolio.component.scss` | Thin scrollbar on `.table-container`; sticky first col in `.holdings-table` |
| `src/app/transaction-history/transaction-history.component.scss` | Thin scrollbar on `.txn-history__table-wrap`; sticky first col in `.txn-history__table` |

---

## 10. Acceptance Criteria

### Desktop (≥ 1280 px)
- [ ] Holdings table, Ledger table, and market-index bar are visually identical to pre-patch state.
- [ ] No horizontal scrollbar visible on any page in normal use.

### Mobile (≤ 640 px — Chrome DevTools iPhone 14 Pro or equivalent)
- [ ] Market-index bar: touch-dragging left/right scrolls through all indices. No scrollbar chrome visible.
- [ ] Holdings table: swipe reveals all columns; Ticker column pinned left with no bleed-through.
- [ ] Ledger table: swipe reveals all columns; Date column pinned left with no bleed-through.
- [ ] Pinned columns carry correct surface background — no transparent ghost effect.
- [ ] `tabular-nums` alignment on numeric columns preserved.

### Build
- [ ] `npm run build:prod` passes — no SCSS errors, no `anyComponentStyle` budget overrun.
- [ ] `npm run lint` passes with no new errors.

---

## 11. Testing

1. `npm start` → `http://localhost:4200` in Chrome.
2. DevTools → Responsive → **iPhone 14 Pro** (393 × 852).
3. Portfolio page with holdings → swipe top bar left; swipe holdings table right.
4. Ledger page → swipe table right; confirm Date column sticks.
5. Switch back to 1440 × 900 → confirm no regressions.
6. `npm run build:prod` → confirm zero budget errors.
