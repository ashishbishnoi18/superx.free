// Command scraper is the read-side worker for SuperX.
//
// It reads line-delimited JSON requests on stdin and writes
// line-delimited JSON responses on stdout, so the Elixir control plane
// can drive it over a Port and supervise it like any other process.
//
// Writes (publishing, DMs) go through the official X API and never touch
// this binary.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

func main() {
	client := NewClient()

	in := bufio.NewScanner(os.Stdin)
	// Requests are small, but timeline cursors can be long.
	in.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	out := &writer{w: bufio.NewWriter(os.Stdout)}

	// Handshake, so the control plane can log what it started and refuse
	// to dispatch work the binary can't do.
	out.send(Response{
		Type: "ready",
		Data: map[string]any{
			"contract":   "superx.scraper/v1",
			"ops":        []string{"search", "profile", "ping"},
			"configured": client.Configured(),
		},
	})

	for in.Scan() {
		line := in.Bytes()
		if len(line) == 0 {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			out.send(Response{Type: "error", Message: fmt.Sprintf("bad request: %v", err)})
			continue
		}

		// Serial by design: X rate-limits per token, so parallelism here
		// would only produce 429s faster. Scale by running more workers.
		handle(client, req, out)
	}

	if err := in.Err(); err != nil {
		out.send(Response{Type: "error", Message: fmt.Sprintf("stdin: %v", err)})
	}
}

func handle(client *Client, req Request, out *writer) {
	switch req.Op {
	case "ping":
		out.send(Response{ID: req.ID, Type: "done", Data: map[string]any{
			"configured": client.Configured(),
		}})

	case "search":
		var params SearchParams
		if err := json.Unmarshal(req.Params, &params); err != nil {
			out.send(Response{ID: req.ID, Type: "error", Message: fmt.Sprintf("bad params: %v", err)})
			return
		}
		runSearch(client, req.ID, params, out)

	case "profile":
		var params ProfileParams
		if err := json.Unmarshal(req.Params, &params); err != nil {
			out.send(Response{ID: req.ID, Type: "error", Message: fmt.Sprintf("bad params: %v", err)})
			return
		}
		// Profile timelines run through the same search grammar, which
		// avoids a second GraphQL surface to keep working.
		runSearch(client, req.ID, SearchParams{
			Query: "from:" + params.Handle,
			Limit: params.Limit,
		}, out)

	default:
		out.send(Response{ID: req.ID, Type: "error", Message: "unknown op: " + req.Op})
	}
}

// runSearch pages until it has enough posts or the timeline runs dry.
func runSearch(client *Client, id string, params SearchParams, out *writer) {
	target := params.Limit
	if target <= 0 {
		target = 50
	}

	sent := 0
	cursor := params.Cursor

	for sent < target {
		page := params
		page.Cursor = cursor
		page.Limit = target - sent

		posts, next, err := client.Search(page)
		if err != nil {
			// Emit what we already streamed rather than discarding it —
			// partial ingestion is still useful.
			out.send(Response{ID: id, Type: "error", Message: err.Error(), Count: sent})
			return
		}

		for _, post := range posts {
			out.send(Response{ID: id, Type: "item", Data: post})
			sent++
		}

		// No cursor, or a page that returned nothing, means the end.
		if next == "" || next == cursor || len(posts) == 0 {
			break
		}

		cursor = next
	}

	out.send(Response{ID: id, Type: "done", Count: sent, Data: map[string]any{"cursor": cursor}})
}

// writer serialises stdout writes so concurrent sends can't interleave
// halfway through a line.
type writer struct {
	mu sync.Mutex
	w  *bufio.Writer
}

func (o *writer) send(resp Response) {
	o.mu.Lock()
	defer o.mu.Unlock()

	payload, err := json.Marshal(resp)
	if err != nil {
		return
	}

	o.w.Write(payload)
	o.w.WriteByte('\n')
	o.w.Flush()
}
