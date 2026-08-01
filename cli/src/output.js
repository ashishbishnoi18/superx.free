const COUNT_ORDER = ["all", "for_you", "products", "trending", "media", "viral"]

export function printWhoami(body, host, output) {
  output.write(`${accountName(body.account)}\nHost: ${host}\n`)
}

export function printQueue(body, output) {
  const posts = body.posts || []
  output.write(`${accountName(body.account)} · ${body.status} · ${count(posts.length, "post")}\n`)

  if (posts.length === 0) {
    output.write(`No ${body.status} posts.\n`)
    return
  }

  for (const post of posts) {
    output.write(`\n${post.id}  ${post.status}${postTime(post)}\n`)
    printSegments(post.segments, output)
    if (post.error) output.write(`  Error: ${post.error}\n`)
    if (post.permalink) output.write(`  ${post.permalink}\n`)
  }
}

export function printShelf(body, output) {
  const drafts = body.drafts || []
  output.write(`${accountName(body.account)} · Ready to Post · ${count(drafts.length, "draft")}\n`)

  const counts = COUNT_ORDER
    .filter(key => key !== "all" && body.counts?.[key])
    .map(key => `${label(key)} ${body.counts[key]}`)

  if (counts.length > 0) output.write(`${counts.join(" · ")}\n`)

  if (drafts.length === 0) {
    output.write("No drafts are waiting for review.\n")
    return
  }

  for (const draft of drafts) {
    const score = draft.score == null ? "" : ` · score ${formatNumber(draft.score)}`
    output.write(`\n${draft.id}  ${label(draft.kind)}${score}\n`)
    printSegments(draft.segments, output)
  }
}

export function printAnalytics(body, output) {
  const summary = body.summary || {}
  output.write(`${accountName(body.account)} · Last ${body.days} days\n`)
  metric(output, "Followers", summary.followers, signed(summary.followers_change))
  metric(output, "Posts", summary.posts)
  metric(output, "Impressions", summary.impressions)
  metric(output, "Engagements", summary.engagements)
  metric(output, "Likes", summary.likes)
  metric(output, "Replies", summary.replies)
  metric(output, "Reposts", summary.reposts)
}

export function printDraft(body, output) {
  output.write(`Draft created.\nID: ${body.post.id}\n`)
  printSegments(body.post.segments, output)
  output.write("Review the draft before scheduling it.\n")
}

export function printScheduled(body, output) {
  output.write(`Scheduled ${body.post.id} for ${formatDate(body.post.scheduled_at)}.\n`)
}

function accountName(account) {
  if (!account) return "No X account selected"

  const name = account.display_name ? `${account.display_name} ` : ""
  return `${name}(@${account.handle})`
}

function count(value, noun) {
  return `${value} ${noun}${value === 1 ? "" : "s"}`
}

function label(value) {
  return value.replaceAll("_", " ")
}

function printSegments(segments = [], output) {
  segments.forEach((segment, index) => {
    const prefix = segments.length > 1 ? `  ${index + 1}/${segments.length} ` : "  "
    const lines = String(segment.text || "").split("\n")
    output.write(`${prefix}${lines.shift() || ""}\n`)
    for (const line of lines) output.write(`  ${line}\n`)
  })
}

function postTime(post) {
  const value = post.scheduled_at || post.published_at || post.failed_at
  return value ? ` · ${formatDate(value)}` : ""
}

function formatDate(value) {
  if (!value) return "an unspecified time"

  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? value : date.toISOString()
}

function metric(output, name, value, suffix = "") {
  output.write(`${name.padEnd(13)} ${formatNumber(value)}${suffix}\n`)
}

function formatNumber(value) {
  if (typeof value !== "number") return "0"
  return new Intl.NumberFormat("en-GB", {maximumFractionDigits: 2}).format(value)
}

function signed(value) {
  if (typeof value !== "number" || value === 0) return ""
  return ` (${value > 0 ? "+" : ""}${formatNumber(value)})`
}
