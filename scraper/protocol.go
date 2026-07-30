package main

import "encoding/json"

// The worker speaks line-delimited JSON over stdin/stdout. One request
// per line in, zero or more responses per line out, each tagged with the
// request id so the control plane can demultiplex concurrent work.
//
// Keeping the contract this narrow means the Elixir side never needs to
// know how a source is fetched — only what a post looks like.

type Request struct {
	ID     string          `json:"id"`
	Op     string          `json:"op"`
	Params json.RawMessage `json:"params"`
}

type Response struct {
	ID      string `json:"id"`
	Type    string `json:"type"` // item | done | error | log
	Data    any    `json:"data,omitempty"`
	Count   int    `json:"count,omitempty"`
	Message string `json:"message,omitempty"`
}

// SearchParams drives the corpus ingestion op.
type SearchParams struct {
	Query    string `json:"query"`
	MinLikes int    `json:"min_likes"`
	Limit    int    `json:"limit"`
	Lang     string `json:"lang"`
	// Cursor lets a caller resume a previous page.
	Cursor string `json:"cursor"`
}

// ProfileParams fetches recent posts for one account, used by the
// Signals profile watch.
type ProfileParams struct {
	Handle string `json:"handle"`
	Limit  int    `json:"limit"`
}

// Post is the normalised shape the control plane persists. Field names
// match SuperX.Content.CorpusPost so ingestion is a straight map.
type Post struct {
	XPostID         string  `json:"x_post_id"`
	AuthorHandle    string  `json:"author_handle"`
	AuthorName      string  `json:"author_name"`
	AuthorAvatarURL string  `json:"author_avatar_url"`
	AuthorFollowers int     `json:"author_followers"`
	AuthorVerified  bool    `json:"author_verified"`
	Text            string  `json:"text"`
	Lang            string  `json:"lang"`
	Likes           int     `json:"likes"`
	Reposts         int     `json:"reposts"`
	Replies         int     `json:"replies"`
	Quotes          int     `json:"quotes"`
	Bookmarks       int     `json:"bookmarks"`
	Impressions     int     `json:"impressions"`
	PostedAt        string  `json:"posted_at"` // RFC3339
	Media           []Media `json:"media"`
	IsThread        bool    `json:"is_thread"`
}

type Media struct {
	Type string `json:"type"`
	URL  string `json:"url"`
}
