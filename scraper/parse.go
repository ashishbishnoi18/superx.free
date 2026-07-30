package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"
)

// X's timeline response is a deeply nested, weakly-typed tree whose exact
// shape varies by entry type. Rather than model all of it, we walk it
// generically and pull out the two things we care about: tweet results
// and the pagination cursor.
//
// Everything is defensive — a shape change should cost us some posts,
// not crash the worker.

func parseSearchTimeline(body []byte) ([]Post, string, error) {
	var root map[string]any
	if err := json.Unmarshal(body, &root); err != nil {
		return nil, "", fmt.Errorf("decode timeline: %w", err)
	}

	if errs, ok := root["errors"].([]any); ok && len(errs) > 0 {
		if first, ok := errs[0].(map[string]any); ok {
			return nil, "", fmt.Errorf("x graphql error: %v", first["message"])
		}
	}

	var (
		posts  []Post
		cursor string
		seen   = map[string]bool{}
	)

	walk(root, func(node map[string]any) {
		switch node["__typename"] {
		case "Tweet", "TweetWithVisibilityResults":
			if post, ok := parseTweet(node); ok && !seen[post.XPostID] {
				seen[post.XPostID] = true
				posts = append(posts, post)
			}
		case "TimelineTimelineCursor":
			if node["cursorType"] == "Bottom" {
				if value, ok := node["value"].(string); ok {
					cursor = value
				}
			}
		}
	})

	return posts, cursor, nil
}

// walk visits every map in the tree, depth first.
func walk(node any, visit func(map[string]any)) {
	switch typed := node.(type) {
	case map[string]any:
		visit(typed)
		for _, child := range typed {
			walk(child, visit)
		}
	case []any:
		for _, child := range typed {
			walk(child, visit)
		}
	}
}

func parseTweet(node map[string]any) (Post, bool) {
	// TweetWithVisibilityResults wraps the real tweet a level down.
	if inner, ok := node["tweet"].(map[string]any); ok {
		node = inner
	}

	legacy, ok := node["legacy"].(map[string]any)
	if !ok {
		return Post{}, false
	}

	id := str(node["rest_id"])
	if id == "" {
		id = str(legacy["id_str"])
	}
	if id == "" {
		return Post{}, false
	}

	text := str(legacy["full_text"])
	if text == "" {
		return Post{}, false
	}

	post := Post{
		XPostID:     id,
		Text:        text,
		Lang:        str(legacy["lang"]),
		Likes:       num(legacy["favorite_count"]),
		Reposts:     num(legacy["retweet_count"]),
		Replies:     num(legacy["reply_count"]),
		Quotes:      num(legacy["quote_count"]),
		Bookmarks:   num(legacy["bookmark_count"]),
		Impressions: num(node["views"], "count"),
		PostedAt:    parseTime(str(legacy["created_at"])),
		// A tweet that opens its own conversation is the head of a thread.
		IsThread: str(legacy["conversation_id_str"]) == id && num(legacy["reply_count"]) > 0,
	}

	if user, ok := digUser(node); ok {
		post.AuthorHandle = str(user["screen_name"])
		post.AuthorName = str(user["name"])
		post.AuthorAvatarURL = str(user["profile_image_url_https"])
		post.AuthorFollowers = num(user["followers_count"])
		post.AuthorVerified = boolean(user["verified"]) || boolean(user["is_blue_verified"])
	}

	if post.AuthorHandle == "" {
		return Post{}, false
	}

	post.Media = parseMedia(legacy)

	return post, true
}

// The author sits under core.user_results.result, with the interesting
// fields split between `legacy` and the top level depending on version.
func digUser(node map[string]any) (map[string]any, bool) {
	core, ok := node["core"].(map[string]any)
	if !ok {
		return nil, false
	}

	results, ok := core["user_results"].(map[string]any)
	if !ok {
		return nil, false
	}

	result, ok := results["result"].(map[string]any)
	if !ok {
		return nil, false
	}

	merged := map[string]any{}

	if legacy, ok := result["legacy"].(map[string]any); ok {
		for k, v := range legacy {
			merged[k] = v
		}
	}
	// Newer responses hoist the name and handle out of legacy.
	if core, ok := result["core"].(map[string]any); ok {
		for k, v := range core {
			merged[k] = v
		}
	}
	if avatar, ok := result["avatar"].(map[string]any); ok {
		if url, ok := avatar["image_url"].(string); ok {
			merged["profile_image_url_https"] = url
		}
	}
	if verified, ok := result["is_blue_verified"]; ok {
		merged["is_blue_verified"] = verified
	}

	return merged, len(merged) > 0
}

func parseMedia(legacy map[string]any) []Media {
	entities, ok := legacy["extended_entities"].(map[string]any)
	if !ok {
		if entities, ok = legacy["entities"].(map[string]any); !ok {
			return nil
		}
	}

	items, ok := entities["media"].([]any)
	if !ok {
		return nil
	}

	var media []Media
	for _, item := range items {
		entry, ok := item.(map[string]any)
		if !ok {
			continue
		}
		media = append(media, Media{
			Type: str(entry["type"]),
			URL:  str(entry["media_url_https"]),
		})
	}

	return media
}

// --- Coercion helpers ------------------------------------------------------

func str(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	return ""
}

// num reads an integer that may arrive as a float, a string, or nested
// one level under `path`.
func num(value any, path ...string) int {
	for _, key := range path {
		nested, ok := value.(map[string]any)
		if !ok {
			return 0
		}
		value = nested[key]
	}

	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case string:
		parsed, err := strconv.Atoi(typed)
		if err != nil {
			return 0
		}
		return parsed
	default:
		return 0
	}
}

func boolean(value any) bool {
	b, ok := value.(bool)
	return ok && b
}

// X emits "Wed Oct 10 20:19:24 +0000 2018".
func parseTime(raw string) string {
	if raw == "" {
		return time.Now().UTC().Format(time.RFC3339)
	}

	parsed, err := time.Parse(time.RubyDate, raw)
	if err != nil {
		return time.Now().UTC().Format(time.RFC3339)
	}

	return parsed.UTC().Format(time.RFC3339)
}
