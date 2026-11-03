import { isBackspace, isDown, isEnter, isEscape, isUp } from "./keys.js";
import { cyan, dim, paint, yellow } from "./style.js";
import { fit } from "./width.js";
export class SelectList {
    items;
    index = 0;
    filter = "";
    maxVisible = 8;
    onSelect = null;
    onCancel = null;
    constructor(items) {
        this.items = items;
    }
    setMaxVisible(rows) {
        this.maxVisible = Math.max(1, rows);
    }
    setSelectedId(id) {
        const found = this.filtered().findIndex((item) => item.id === id);
        this.index = found >= 0 ? found : 0;
    }
    filterLength() {
        return this.filter.length;
    }
    selected() {
        return this.filtered()[this.index];
    }
    handleInput(data) {
        const items = this.filtered();
        if (isEscape(data)) {
            if (this.filter) {
                this.filter = "";
                this.index = 0;
                return;
            }
            this.onCancel?.();
            return;
        }
        if (isEnter(data)) {
            const item = items[this.index];
            if (item)
                this.onSelect?.(item);
            return;
        }
        if (isUp(data) || (data === "k" && this.filter.length === 0)) {
            if (items.length === 0)
                return;
            this.index = (this.index - 1 + items.length) % items.length;
            return;
        }
        if (isDown(data) || (data === "j" && this.filter.length === 0)) {
            if (items.length === 0)
                return;
            this.index = (this.index + 1) % items.length;
            return;
        }
        if (isBackspace(data)) {
            this.filter = this.filter.slice(0, -1);
            this.index = 0;
            return;
        }
        if (/^[a-zA-Z0-9._:-]$/.test(data)) {
            this.filter += data.toLowerCase();
            this.index = 0;
        }
    }
    render(width) {
        const items = this.filtered();
        const rows = [];
        if (items.length === 0) {
            rows.push(fit(paint("沒有符合的項目", dim), width));
        }
        else {
            if (this.index >= items.length)
                this.index = 0;
            const windowSize = Math.min(this.maxVisible, items.length);
            let start = Math.max(0, this.index - Math.floor(windowSize / 2));
            if (start + windowSize > items.length)
                start = Math.max(0, items.length - windowSize);
            for (let row = start; row < start + windowSize; row += 1) {
                const item = items[row];
                if (!item)
                    continue;
                const selected = row === this.index;
                const mark = item.destructive ? "!" : " ";
                const text = `${selected ? "›" : " "} ${mark} ${item.section}  ${item.label}  ${item.description}`;
                const colored = selected ? paint(text, item.destructive ? yellow : cyan) : text;
                rows.push(fit(colored, width));
            }
            if (items.length > windowSize) {
                rows.push(fit(paint(`${this.index + 1}/${items.length}`, dim), width));
            }
        }
        if (this.filter)
            rows.push(fit(paint(`篩選: ${this.filter}    Esc 清除`, dim), width));
        return rows;
    }
    filtered() {
        const query = this.filter.toLowerCase();
        if (!query)
            return [...this.items];
        return this.items.filter((item) => `${item.id} ${item.section} ${item.label} ${item.description}`.toLowerCase().includes(query));
    }
}
