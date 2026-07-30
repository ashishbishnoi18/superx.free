package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Client talks to X's public web endpoints using a guest token — the
// same handshake the logged-out web client performs.
//
// The endpoint path and query id are configuration rather than
// constants: X revises both regularly, and a redeploy to change a string
// is cheaper than a code change.
type Client struct {
	http        *http.Client
	bearer      string
	searchPath  string
	rate        *rateLimiter
	mu          sync.Mutex
	guestToken  string
	guestExpiry time.Time
}

func NewClient() *Client {
	transport := &http.Transport{
		MaxIdleConns:        20,
		IdleConnTimeout:     60 * time.Second,
		TLSHandshakeTimeout: 15 * time.Second,
	}

	// Honours HTTPS_PROXY/HTTP_PROXY so operators can route egress
	// through their own infrastructure.
	transport.Proxy = http.ProxyFromEnvironment

	return &Client{
		http: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
		},
		bearer:     env("X_WEB_BEARER", ""),
		searchPath: env("X_SEARCH_PATH", ""),
		// Deliberately conservative. Hammering a public endpoint is both
		// rude and the fastest way to get an IP blocked.
		rate: newRateLimiter(durationEnv("X_MIN_REQUEST_INTERVAL", 2*time.Second)),
	}
}

// Configured reports whether enough is set to attempt live requests.
func (c *Client) Configured() bool {
	return c.bearer != "" && c.searchPath != ""
}

// Search returns posts matching a query, filtered by engagement.
func (c *Client) Search(p SearchParams) ([]Post, string, error) {
	if !c.Configured() {
		return nil, "", fmt.Errorf("scraper is not configured: set X_WEB_BEARER and X_SEARCH_PATH")
	}

	token, err := c.ensureGuestToken()
	if err != nil {
		return nil, "", fmt.Errorf("guest token: %w", err)
	}

	query := p.Query
	if p.MinLikes > 0 {
		// X's search grammar does the engagement filtering server-side,
		// which is far cheaper than pulling everything and filtering here.
		query = fmt.Sprintf("%s min_faves:%d", query, p.MinLikes)
	}
	if p.Lang != "" {
		query = fmt.Sprintf("%s lang:%s", query, p.Lang)
	}
	query += " -filter:replies"

	variables := map[string]any{
		"rawQuery":    query,
		"count":       clamp(p.Limit, 1, 100),
		"product":     "Top",
		"querySource": "typed_query",
	}
	if p.Cursor != "" {
		variables["cursor"] = p.Cursor
	}

	body, err := c.graphql(token, variables)
	if err != nil {
		return nil, "", err
	}

	return parseSearchTimeline(body)
}

func (c *Client) graphql(guestToken string, variables map[string]any) ([]byte, error) {
	c.rate.wait()

	varsJSON, _ := json.Marshal(variables)

	features := env("X_SEARCH_FEATURES", "{}")

	endpoint := fmt.Sprintf(
		"https://api.x.com/graphql/%s?variables=%s&features=%s",
		c.searchPath,
		url.QueryEscape(string(varsJSON)),
		url.QueryEscape(features),
	)

	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("authorization", "Bearer "+c.bearer)
	req.Header.Set("x-guest-token", guestToken)
	req.Header.Set("content-type", "application/json")
	req.Header.Set("user-agent", userAgent())
	req.Header.Set("accept-language", "en-US,en;q=0.9")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	payload, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}

	switch {
	case resp.StatusCode == http.StatusTooManyRequests:
		return nil, fmt.Errorf("rate limited by X (retry after %s)", resp.Header.Get("x-rate-limit-reset"))
	case resp.StatusCode == http.StatusForbidden, resp.StatusCode == http.StatusUnauthorized:
		// The guest token usually just aged out; drop it so the next call
		// re-activates rather than repeating the failure.
		c.invalidateGuestToken()
		return nil, fmt.Errorf("x rejected the request (%d)", resp.StatusCode)
	case resp.StatusCode >= 300:
		return nil, fmt.Errorf("x returned %d: %s", resp.StatusCode, truncate(string(payload), 200))
	}

	return payload, nil
}

// ensureGuestToken activates a guest session, reusing it until it ages
// out. X ties rate limits to the token, so churning them is worse than
// keeping one.
func (c *Client) ensureGuestToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.guestToken != "" && time.Now().Before(c.guestExpiry) {
		return c.guestToken, nil
	}

	c.rate.wait()

	req, err := http.NewRequest(http.MethodPost, "https://api.x.com/1.1/guest/activate.json", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("authorization", "Bearer "+c.bearer)
	req.Header.Set("user-agent", userAgent())

	resp, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("activate returned %d: %s", resp.StatusCode, truncate(string(body), 200))
	}

	var payload struct {
		GuestToken string `json:"guest_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if payload.GuestToken == "" {
		return "", fmt.Errorf("activate returned no guest_token")
	}

	c.guestToken = payload.GuestToken
	c.guestExpiry = time.Now().Add(2 * time.Hour)

	return c.guestToken, nil
}

func (c *Client) invalidateGuestToken() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.guestToken = ""
}

// rateLimiter spaces requests by a minimum interval.
type rateLimiter struct {
	mu       sync.Mutex
	interval time.Duration
	last     time.Time
}

func newRateLimiter(interval time.Duration) *rateLimiter {
	return &rateLimiter{interval: interval}
}

func (r *rateLimiter) wait() {
	r.mu.Lock()
	defer r.mu.Unlock()

	if elapsed := time.Since(r.last); elapsed < r.interval {
		// A little jitter keeps a fleet of workers from synchronising into
		// bursts against the same endpoint.
		jitter := time.Duration(rand.Int63n(int64(r.interval / 4)))
		time.Sleep(r.interval - elapsed + jitter)
	}

	r.last = time.Now()
}

func userAgent() string {
	return env("X_USER_AGENT",
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "+
			"(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func durationEnv(key string, fallback time.Duration) time.Duration {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	if ms, err := strconv.Atoi(raw); err == nil {
		return time.Duration(ms) * time.Millisecond
	}
	return fallback
}

func clamp(value, lo, hi int) int {
	if value < lo {
		return lo
	}
	if value > hi {
		return hi
	}
	return value
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}
