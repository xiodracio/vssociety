# VARONIS

Static site for **VARONIS — India’s First Secret Society**. Plain HTML/CSS/JS, no build step.

## Structure

```
index.html            main page (3D membership card + access terminal, three.js r128)
confidential.html     hidden page, unlocked by the correct code on the terminal
404.html              not-found page
assets/               logo mark, wordmark, card front/back textures
favicon-32.png        favicon
apple-touch-icon.png  home-screen icon
robots.txt
.nojekyll             tells GitHub Pages to serve files as-is
```

## Deploy on GitHub Pages

1. Create a repo and upload everything in this folder to the repo root (keep `.nojekyll`).
2. Go to **Settings → Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**, pick `main` and `/ (root)`, then Save.
4. The site goes live at `https://<username>.github.io/<repo>/` within a minute or two.

Custom domain: add it under Settings → Pages, and add a file named `CNAME` containing the domain.

## Run locally

Open it through a local server, not by double-clicking the file. Browsers block WebGL textures loaded from `file://`, so the 3D card would fall back to a flat image.

```
python3 -m http.server 8000
```

Then visit http://localhost:8000.

## Notes

- The 3D card and fonts load from CDNs (cdnjs, Google Fonts), so visitors need an internet connection.
- For rich link previews, add `og:image` and `og:url` meta tags with absolute URLs once the final address is known.

## Access terminal and Confidential page

- The terminal sits under the Status section. The correct code is set by `const CODE="66603"` near the top of the last `<script>` in `index.html`. Change it there.
- A correct code shows Access Granted, then sends the visitor to `confidential.html`. The header's Confidential link stays locked until then.
- This is a static site, so the gate runs in the browser. It keeps casual visitors out, but the code and page are visible to anyone who views the page source. Do not put anything truly secret on it. Real protection needs a server-side login.

## Global Archive, points, moderators and founder tools

- After signing in, a member sees **Enter Global Archive** under the digital card: a read-only feed posted by The Archive with masked member codes (e.g. `FM26***`). There are no chat channels.
- The feed is generated for atmosphere. The only real entries are points awards, which post automatically with the member's code masked.
- **Points** show under the digital card. Only the Founder console or a moderator can award or deduct them.
- The Founder console lists every member with code, password, points and join date, plus a search bar. Codes can be generated or assigned (5 digits, prefix follows the status).
- **Moderators:** the Founder taps **Make moderator** on a member. That member then sees **Moderator console** on their card page and can add members, search, award points, set passwords and remove members. Moderators cannot appoint or remove moderators, and cannot see or change other moderators' accounts.
- Members, passwords, points, roles and the Archive live in **Supabase** (see below), so they are shared across every device in real time.

## Go live with Supabase

The portal is `dashboard.html`. It needs a free Supabase project for storage and realtime. Nothing else changes: the site stays plain HTML on GitHub Pages.

1. Create a project at supabase.com.
2. **SQL Editor → New query**, paste all of `supabase/schema.sql`, **Run**. (Safe to re-run later.)
3. Open `supabase/founder.sql`, change the two values at the top to your real Founder username and a strong password (10+ characters), paste it into a new SQL Editor query and **Run**. Do this in the SQL Editor only. Do not commit your real password to GitHub.
4. **Project Settings → API**: copy the **Project URL** and the **anon public** key into `supabase-config.js`. Never use the `service_role` key anywhere in the site.
5. Check **Database → Publications → supabase_realtime** lists `feed` and `pings` (the schema adds them).
6. Upload everything to GitHub Pages as described above and open `/dashboard.html`.

### How it works

- Sign-in, member creation, points, passwords, moderator roles and removal all go through database functions (`vr_*`). Each checks a session token, so roles are enforced by the database, not just the interface.
- Every table is locked (Row Level Security with no public policies). The public key can only call those functions and read two things: the Archive feed (masked codes only) and a change counter that tells open pages to refresh.
- **Global Archive:** one shared feed in the database. Open pages receive new entries instantly over Supabase Realtime (a green Live dot shows the connection). A fifteen-second poll covers dropped connections. While any member has the Archive open, the database adds atmospheric entries on a shared timer, so everyone sees the same stream. Points awards post automatically with the code masked.
- **Live everywhere:** a new member can sign in from any device the moment the Founder creates them. Points, moderator status and removals update open pages without a reload. A removed member, or one whose password is reset, is signed out immediately.
- **Passwords** are stored hashed (bcrypt) for sign-in. A readable copy is kept in `member_secrets` only so the Founder or a moderator can see it in the console. To stop keeping readable copies, run `drop table public.member_secrets;` and the console will show "Not recorded".
- **Sign-in lockout** is enforced by the database per username: after 5 wrong tries the wait doubles from 30 seconds up to 15 minutes. Sessions last 24 hours.
- The access terminal and `confidential.html` on the main site are unchanged and still run in the browser.

### Troubleshooting

- "Portal is not connected yet": `supabase-config.js` still has the placeholders.
- "Database not set up yet": `supabase/schema.sql` has not been run on this project.
- Archive shows an empty feed and no Live dot: confirm step 5, and that the project is not paused (free projects pause after a week of no use).
