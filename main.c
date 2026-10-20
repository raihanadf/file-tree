// filetree: a literal file tree for the terminal.
// directories grow as pixel-art branches, files hang off twigs.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

typedef struct node {
    char *name, *path;
    int is_dir, loaded, open, err;
    float grow;                    // 0..1, how much of the branch is drawn
    struct node *parent, **kids;
    int nkids;
    // layout, recomputed every frame
    float ox, oy, ang, len, width; // branch origin, direction, length, base thickness
    float at, slot, lx, ly;        // spot on the parent branch, space it takes, label anchor
    int side, lrow, lcol, lend;
    uint32_t seed;
} node;

typedef struct {
    char ch[8];
    int style; // 0 none, 1 file, 2 dir, 3 selected, 4 bar
} cell;

static const uint32_t bark[] = {0x1c1714, 0x3b302a, 0x5a4a3c, 0x7d6b58, 0x9a8f80};
static const uint32_t moss[] = {0x5fa82a, 0x7ec832, 0xa6e22e, 0xc8e64a, 0xe4f05a};
static const uint32_t twig[] = {0x6e6458, 0x8f8578, 0x4d443c};

static struct termios saved;
static int tty, cols, rows, show_hidden, moving;
static uint32_t *pix;
static node *vis[8192];
static int nvis;
static float camx, camy;

static uint32_t hash(uint32_t a, uint32_t b, uint32_t c) {
    uint32_t x = a * 374761393u + b * 668265263u + c * 2246822519u;
    x = (x ^ (x >> 13)) * 1274126177u;
    return x ^ (x >> 16);
}

static int by_kind_then_name(const void *a, const void *b) {
    const node *x = *(node *const *)a, *y = *(node *const *)b;
    if (x->is_dir != y->is_dir) return y->is_dir - x->is_dir;
    return strcasecmp(x->name, y->name);
}

static node *new_node(const char *name, const char *path, node *parent) {
    node *n = calloc(1, sizeof *n);
    struct stat st;
    n->name = strdup(name);
    n->path = strdup(path);
    n->parent = parent;
    n->is_dir = stat(path, &st) == 0 && S_ISDIR(st.st_mode);
    n->seed = hash((uint32_t)(uintptr_t)n, (uint32_t)strlen(path), 7);
    return n;
}

static void load_kids(node *n) {
    DIR *d = opendir(n->path);
    struct dirent *e;
    char path[PATH_MAX];
    int cap = 0;
    n->loaded = 1;
    if (!d) {
        n->err = errno;
        return;
    }
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (e->d_name[0] == '.' && !show_hidden) continue;
        if (n->nkids == cap) {
            cap = cap ? cap * 2 : 16;
            n->kids = realloc(n->kids, cap * sizeof *n->kids);
        }
        snprintf(path, sizeof path, "%s/%s", n->path, e->d_name);
        n->kids[n->nkids++] = new_node(e->d_name, path, n);
    }
    closedir(d);
    qsort(n->kids, n->nkids, sizeof *n->kids, by_kind_then_name);
}

// point at distance s along a branch. it sprouts at its angle, then levels out
// towards horizontal, with a slow wobble so it looks grown, not drawn
static void branch_point(node *n, float s, float *x, float *y) {
    float off = (sinf(s * 0.06f + n->seed % 100) * 2.f + sinf(s * 0.021f + n->seed % 37) * 4.f) * fminf(1, s / 12);
    *x = n->ox + s * cosf(n->ang * 0.5f);
    *y = n->oy + sinf(n->ang) * 40 * (1 - expf(-s / 40)) + off;
}

// bottom-up: animate growth and work out how long every open branch needs to be
static float measure(node *n, float dt) {
    float s = 16, before = n->grow;
    if (!n->is_dir) return 0;
    n->grow += (n->open ? 70.f : -160.f) * dt / fmaxf(n->len, 20);
    n->grow = fminf(1, fmaxf(0, n->grow));
    if (n->grow != before) moving = 1;
    for (int i = 0; i < n->nkids; i++) {
        node *k = n->kids[i];
        k->slot = 10 + strlen(k->name) * 0.8f + measure(k, dt) * 0.35f;
        s += k->slot;
    }
    n->len = s + 10;
    return n->len * n->grow;
}

// top-down: hang every child off its parent's branch, alternating sides
static void place(node *n) {
    float s = 16, px, py;
    for (int i = 0; i < n->nkids; i++) {
        node *k = n->kids[i];
        k->at = s + k->slot * 0.5f;
        k->side = i % 2 ? 1 : -1;
        s += k->slot;
        branch_point(n, k->at, &px, &py);
        k->ox = px;
        k->oy = py;
        k->ang = k->side * 0.8f;
        k->width = fmaxf(1, n->width * (1 - k->at / n->len * 0.5f) * 0.7f);
        if (k->is_dir) {
            // up and to the left of the junction, out of the way of its own branch
            k->lx = px - strlen(k->name) - 5;
            k->ly = py + k->side * (4 + k->width);
            place(k);
        } else {
            k->lx = px + cosf(k->ang) * 8 + 1;
            k->ly = py + sinf(k->ang) * 8 + k->side * ((i / 2) % 2 ? 4 : 1);
        }
    }
}

static void plot(float x, float y, uint32_t c) {
    int sx = (int)floorf(x - camx + cols / 2), sy = (int)floorf(y - camy + rows);
    if (sx >= 0 && sx < cols && sy >= 0 && sy < rows * 2) pix[sy * cols + sx] = c;
}

static void draw(node *n) {
    float vlen = n->len * n->grow, x, y;
    for (float s = 0; s < vlen; s += 0.5f) {
        float w = fmaxf(1, n->width * (1 - 0.7f * s / n->len)), r = w / 2;
        int si = (int)s;
        branch_point(n, s, &x, &y);
        for (float dy = -r; dy <= r; dy += 1)
            for (float dx = -r; dx <= r; dx += 1)
                if (dx * dx + dy * dy <= r * r + 0.3f) {
                    uint32_t h = hash((int)(x + dx), (int)(y + dy), n->seed);
                    plot(x + dx, y + dy, bark[h % 5 / (dy < 0 ? 2 : 1)]);
                }
        if (s != si) continue;
        // moss, thick near the base and thinning towards the tip
        for (int m = 0; m < 3; m++) {
            uint32_t h = hash(si, m, n->seed);
            if (h % 100 < (1 - s / n->len) * 90)
                plot(x + (int)(h >> 8) % 5 - 2, y - r - (h >> 16) % 3 + 1, moss[(h >> 20) % 5]);
        }
        // the odd bare twig, dotted like the video
        if (si > 6 && hash(si, 99, n->seed) % 19 == 0) {
            uint32_t h = hash(si, 3, n->seed);
            float a = n->ang + (h % 2 ? 0.9f : -0.9f), tl = 3 + h % 7;
            for (float t = 1; t < tl; t += 1)
                if (hash(si, (int)t, h) % 5) plot(x + cosf(a) * t, y + sinf(a) * t, twig[(int)t % 3]);
            plot(x + cosf(a) * tl, y + sinf(a) * tl, moss[h % 5]);
        }
    }
    for (int i = 0; i < n->nkids; i++) {
        node *k = n->kids[i];
        if (k->at > vlen) continue;
        if (nvis < (int)(sizeof vis / sizeof *vis)) vis[nvis++] = k;
        if (k->is_dir) {
            if (k->grow > 0) draw(k);
            continue;
        }
        float tx = k->lx - 1, ty = k->ly - k->side * ((i / 2) % 2 ? 4 : 1);
        float tl = hypotf(tx - k->ox, ty - k->oy);
        for (float t = 0; t < tl; t += 1)
            if (hash(i, (int)t, n->seed) % 4) plot(k->ox + (tx - k->ox) * t / tl, k->oy + (ty - k->oy) * t / tl, twig[(int)t % 3]);
        plot(tx, ty, moss[hash(i, 1, n->seed) % 5]);
    }
}

static void put_text(cell *cells, int row, int col, const char *s, int style) {
    for (; *s && col < cols; s++) {
        if (((unsigned char)*s & 0xc0) == 0x80) {
            // utf-8 continuation byte, glue it onto the previous cell
            if (col > 0 && col <= cols) {
                cell *c = &cells[row * cols + col - 1];
                size_t l = strlen(c->ch);
                if (l < sizeof c->ch - 1) c->ch[l] = *s;
            }
            continue;
        }
        if (col >= 0) {
            cell *c = &cells[row * cols + col];
            memset(c->ch, 0, sizeof c->ch);
            c->ch[0] = *s;
            c->style = style;
        }
        col++;
    }
}

static void render(node *root, node *sel) {
    static const uint32_t style_fg[] = {0, 0x9a948c, 0xe8e4dc, 0x101010, 0x77736d};
    size_t cap = (size_t)cols * rows * 48 + 64, len = 0;
    char *out = malloc(cap), label[PATH_MAX + 8];
    cell *cells = calloc((size_t)cols * rows, sizeof *cells);
    long fg = -1, bg = -1;
    int items = sel->parent ? sel->parent->nkids : root->nkids;

    pix = calloc((size_t)cols * rows * 2, sizeof *pix);
    nvis = 0;
    vis[nvis++] = root;
    draw(root);

    for (int i = 0; i < nvis; i++) {
        node *n = vis[i];
        if (n->is_dir)
            snprintf(label, sizeof label, "%s %s/", n->open ? "▾" : "▸", n->name);
        else
            snprintf(label, sizeof label, "· %s", n->name);
        n->lrow = (int)floorf(n->ly - camy + rows) / 2;
        n->lcol = (int)floorf(n->lx - camx + cols / 2);
        n->lend = n->lcol + (int)strlen(n->name) + 3;
        if (n->lrow > 0 && n->lrow < rows - 1) put_text(cells, n->lrow, n->lcol, label, n == sel ? 3 : n->is_dir ? 2 : 1);
    }
    for (int c = 0; c < cols; c++) {
        put_text(cells, 0, c, " ", 4);
        put_text(cells, rows - 1, c, " ", 4);
    }
    snprintf(label, sizeof label, " %s", root->path);
    put_text(cells, 0, 0, label, 4);
    if (sel->err)
        snprintf(label, sizeof label, " %s: %s", sel->name, strerror(sel->err));
    else
        snprintf(label, sizeof label, " %d items · hjkl/arrows move · enter open · q quit", items);
    put_text(cells, rows - 1, 0, label, 4);

    len += snprintf(out, cap, "\x1b[H");
    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            cell *ce = &cells[r * cols + c];
            uint32_t top = pix[(r * 2) * cols + c], bot = pix[(r * 2 + 1) * cols + c];
            long want_fg, want_bg;
            const char *glyph;
            if (ce->style) {
                want_fg = style_fg[ce->style];
                want_bg = ce->style == 3 ? 0xb4dc5a : -1;
                glyph = ce->ch;
            } else if (top && bot) {
                want_fg = top, want_bg = bot, glyph = "▀";
            } else if (top || bot) {
                want_fg = top ? top : bot, want_bg = -1, glyph = top ? "▀" : "▄";
            } else {
                want_fg = fg, want_bg = -1, glyph = " ";
            }
            if (want_fg != fg || want_bg != bg) {
                len += snprintf(out + len, cap - len, "\x1b[0");
                if (want_fg >= 0) len += snprintf(out + len, cap - len, ";38;2;%ld;%ld;%ld", want_fg >> 16, want_fg >> 8 & 255, want_fg & 255);
                if (want_bg >= 0) len += snprintf(out + len, cap - len, ";48;2;%ld;%ld;%ld", want_bg >> 16, want_bg >> 8 & 255, want_bg & 255);
                len += snprintf(out + len, cap - len, "m");
                fg = want_fg, bg = want_bg;
            }
            len += snprintf(out + len, cap - len, "%s", glyph);
        }
    }
    len += snprintf(out + len, cap - len, "\x1b[0m");
    write(tty, out, len);
    free(out);
    free(cells);
    free(pix);
}

static void on_winch(int sig) { (void)sig; }

int main(int argc, char **argv) {
    char real[PATH_MAX];
    const char *dir = ".";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-a"))
            show_hidden = 1;
        else if (argv[i][0] == '-') {
            fprintf(stderr, "usage: filetree [-a] [dir]\n");
            return 1;
        } else
            dir = argv[i];
    }
    if (!realpath(dir, real)) {
        fprintf(stderr, "filetree: %s: %s\n", dir, strerror(errno));
        return 1;
    }
    // draw on the tty directly so stdout stays free for the picked path
    tty = open("/dev/tty", O_RDWR);
    if (tty < 0) {
        fprintf(stderr, "filetree: /dev/tty: %s\n", strerror(errno));
        return 1;
    }

    char *base = strrchr(real, '/');
    node *root = new_node(base[1] ? base + 1 : real, real, NULL), *sel, *picked = NULL;
    if (!root->is_dir) {
        fprintf(stderr, "filetree: %s: not a directory\n", real);
        return 1;
    }
    load_kids(root);
    root->open = 1;
    root->ox = -20;
    root->width = 6;
    root->lx = -18;
    root->ly = -11;
    sel = root->nkids ? root->kids[0] : root;

    struct termios raw;
    struct sigaction sa = {0};
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);
    tcgetattr(tty, &saved);
    raw = saved;
    raw.c_lflag &= ~(ICANON | ECHO | ISIG);
    raw.c_iflag &= ~(IXON | ICRNL);
    tcsetattr(tty, TCSAFLUSH, &raw);
    dprintf(tty, "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h");

    struct timespec last, now;
    clock_gettime(CLOCK_MONOTONIC, &last);
    int running = 1;
    camx = camy = 0;
    while (running) {
        struct winsize ws;
        ioctl(tty, TIOCGWINSZ, &ws);
        cols = ws.ws_col, rows = ws.ws_row;
        clock_gettime(CLOCK_MONOTONIC, &now);
        float dt = fminf(0.05f, (now.tv_sec - last.tv_sec) + (now.tv_nsec - last.tv_nsec) / 1e9f);
        last = now;

        moving = 0;
        measure(root, dt);
        place(root);
        // follow the selection, but keep the trunk pinned to the left edge when it fits
        float tx = fmaxf(sel->lx + 12, cols / 2.f - 22), ty = sel->ly;
        if (fabsf(tx - camx) > 0.3f || fabsf(ty - camy) > 0.3f) moving = 1;
        camx += (tx - camx) * fminf(1, dt * 6);
        camy += (ty - camy) * fminf(1, dt * 6);
        render(root, sel);

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(tty, &fds);
        struct timeval tv = {0, 16000};
        if (select(tty + 1, &fds, NULL, NULL, moving ? &tv : NULL) <= 0) continue;

        unsigned char buf[64];
        int nread = read(tty, buf, sizeof buf - 1);
        if (nread <= 0) continue;
        buf[nread] = 0;
        node *toggle = NULL;
        for (int i = 0; i < nread; i++) {
            int key = buf[i];
            node *p = sel->parent;
            int idx = 0;
            if (p)
                while (p->kids[idx] != sel) idx++;
            if (key == 27 && buf[i + 1] == '[' && buf[i + 2] == '<') {
                // sgr mouse: \e[<button;x;y(M|m)
                int b, mx, my;
                char kind;
                if (sscanf((char *)buf + i + 3, "%d;%d;%d%c", &b, &mx, &my, &kind) == 4 && b == 0 && kind == 'M')
                    for (int v = 0; v < nvis; v++)
                        if (vis[v]->lrow == my - 1 && mx - 1 >= vis[v]->lcol && mx - 1 < vis[v]->lend) {
                            sel = vis[v];
                            if (sel->is_dir && sel != root) toggle = sel;
                        }
                while (i < nread && buf[i] != 'M' && buf[i] != 'm') i++;
                continue;
            }
            if (key == 27 && buf[i + 1] == '[' && i + 2 < nread) {
                key = "kjlh"[(buf[i + 2] - 'A') & 3];
                i += 2;
            }
            if (key == 'q' || key == 3) running = 0;
            else if ((key == 'j' || key == 'k') && p)
                sel = p->kids[(idx + (key == 'j' ? 1 : p->nkids - 1)) % p->nkids];
            else if (key == 'l' && sel->is_dir) {
                if (!sel->open) toggle = sel;
                else if (sel->nkids) sel = sel->kids[0];
            } else if (key == 'h') {
                if (sel->is_dir && sel->open && sel != root) toggle = sel;
                else if (p) sel = p;
            } else if ((key == '\r' || key == ' ') && sel->is_dir && sel != root)
                toggle = sel;
            else if (key == '\r' && !sel->is_dir) {
                picked = sel;
                running = 0;
            }
        }
        if (toggle && toggle->open) {
            // close the whole subtree so it retracts together
            node *stack[256];
            int top = 0;
            stack[top++] = toggle;
            while (top) {
                node *n = stack[--top];
                n->open = 0;
                for (int k = 0; k < n->nkids && top < 256; k++)
                    if (n->kids[k]->open) stack[top++] = n->kids[k];
            }
            for (node *a = sel; a; a = a->parent)
                if (a == toggle) sel = toggle;
        } else if (toggle) {
            if (!toggle->loaded) load_kids(toggle);
            toggle->open = 1;
        }
    }

    dprintf(tty, "\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l");
    tcsetattr(tty, TCSAFLUSH, &saved);
    if (picked) printf("%s\n", picked->path);
    return 0;
}
