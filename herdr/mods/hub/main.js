// Los paneles de bk en Herdr: un mismo paquete de archivos instalado una vez por vista (mods/bk-<vista>), porque
// una tecla abre un mod por su nombre y no puede pasarle argumentos. view.js dice cuál es cada copia.
import { VIEW } from "./view.js";
import Palette from "./palette.js";
import Out from "./out.js";
import Issues from "./issues.js";
import Prs from "./prs.js";
import Tasks from "./tasks.js";
import New from "./new.js";
import Agents from "./agents.js";
import Sessions from "./sessions.js";
import Changes from "./changes.js";
import Stats from "./stats.js";
import Keys from "./keys.js";
import Song from "./song.js";
import Look from "./look.js";
import Handoff from "./handoff.js";
import Branches from "./branches.js";
import Profiles from "./profiles.js";

const VIEWS = { palette: Palette, out: Out, issues: Issues, prs: Prs, tasks: Tasks, new: New, agents: Agents, sessions: Sessions, changes: Changes, stats: Stats, keys: Keys, song: Song, look: Look, handoff: Handoff, branches: Branches, profiles: Profiles };
export default VIEWS[VIEW] ?? Palette;
