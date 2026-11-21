import type { CalendarInvite } from "../domain/types.js";

interface Prop {
  name: string;
  params: Record<string, string>;
  value: string;
}

/** Parses the first VEVENT of an iCalendar (RFC 5545) body. Returns null when unusable. */
export function parseCalendarInvite(ics: string): CalendarInvite | null {
  const lines = ics.replace(/\r?\n[ \t]/g, "").split(/\r?\n/);
  const calendarProps: Prop[] = [];
  const eventProps: Prop[] = [];
  let inEvent = false;
  let seenEvent = false;

  for (const line of lines) {
    const upper = line.trim().toUpperCase();
    if (upper === "BEGIN:VEVENT") {
      if (seenEvent) break;
      inEvent = true;
      seenEvent = true;
      continue;
    }
    if (upper === "END:VEVENT") {
      inEvent = false;
      continue;
    }
    const prop = parseLine(line);
    if (!prop) continue;
    if (inEvent) eventProps.push(prop);
    else if (!seenEvent) calendarProps.push(prop);
  }
  if (!seenEvent) return null;

  const find = (name: string) => eventProps.find((p) => p.name === name);
  const dtstart = find("DTSTART");
  if (!dtstart) return null;
  const start = parseDateTime(dtstart);
  if (!start) return null;
  const dtend = find("DTEND");
  const end = dtend ? parseDateTime(dtend) : null;

  const organizer = find("ORGANIZER");
  const organizerName = organizer?.params.CN;
  const organizerAddress = organizer?.value.replace(/^mailto:/i, "").trim();

  return {
    method: calendarProps.find((p) => p.name === "METHOD")?.value.trim().toUpperCase() || null,
    summary: unescapeText(find("SUMMARY")?.value ?? ""),
    start: start.value,
    end: end?.value ?? null,
    allDay: start.allDay,
    location: unescapeText(find("LOCATION")?.value ?? "") || null,
    organizer: organizerName || organizerAddress || null,
    recurring: find("RRULE") !== undefined
  };
}

function parseLine(line: string): Prop | null {
  // Property values may contain ":" so split at the first one outside quotes.
  let quoted = false;
  let colon = -1;
  for (let i = 0; i < line.length; i += 1) {
    if (line[i] === '"') quoted = !quoted;
    else if (line[i] === ":" && !quoted) {
      colon = i;
      break;
    }
  }
  if (colon <= 0) return null;

  const [name, ...rawParams] = splitOutsideQuotes(line.slice(0, colon), ";");
  const params: Record<string, string> = {};
  for (const raw of rawParams) {
    const eq = raw.indexOf("=");
    if (eq > 0) {
      params[raw.slice(0, eq).toUpperCase()] = raw.slice(eq + 1).replace(/^"|"$/g, "");
    }
  }
  return { name: name.trim().toUpperCase(), params, value: line.slice(colon + 1) };
}

function splitOutsideQuotes(value: string, separator: string): string[] {
  const parts: string[] = [];
  let quoted = false;
  let current = "";
  for (const char of value) {
    if (char === '"') quoted = !quoted;
    if (char === separator && !quoted) {
      parts.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  parts.push(current);
  return parts;
}

function parseDateTime(prop: Prop): { value: string; allDay: boolean } | null {
  const match = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(prop.value.trim());
  if (!match) return null;
  const [, y, mo, d, h, mi, s, z] = match;
  if (h === undefined) {
    return { value: `${y}-${mo}-${d}`, allDay: true };
  }
  const local = `${y}-${mo}-${d}T${h}:${mi}:${s}`;
  if (z) return { value: `${local}Z`, allDay: false };

  const tzid = prop.params.TZID;
  const utc = tzid ? zonedToUtc(local, tzid) : null;
  // Unknown or missing zone: keep the wall-clock time without an offset.
  return { value: utc ?? local, allDay: false };
}

function zonedToUtc(local: string, timeZone: string): string | null {
  try {
    const asUtc = Date.parse(`${local}Z`);
    const formatter = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric"
    });
    const offsetAt = (instant: number): number => {
      const p = Object.fromEntries(
        formatter.formatToParts(instant).map((part) => [part.type, Number(part.value)])
      );
      return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - instant;
    };
    // Two passes settle the offset across DST boundaries.
    const first = asUtc - offsetAt(asUtc);
    return new Date(asUtc - offsetAt(first)).toISOString().replace(".000Z", "Z");
  } catch {
    return null;
  }
}

function unescapeText(value: string): string {
  return value.replace(/\\([nN,;\\])/g, (_, c: string) => (c === "n" || c === "N" ? "\n" : c)).trim();
}
