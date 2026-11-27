package main

import (
	"context"
	"database/sql"
	"errors"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/luweiCN/token-meter/internal/device"
	"github.com/luweiCN/token-meter/internal/relay"
)

const defaultPeerListen = "127.0.0.1:47732"

// Inbound and outbound permissions are directional. A viewer is allowed to read
// us. A source is a node we can read without granting it access to this device.
type peerRoute = device.Route

type pairedDevice struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Role     string `json:"role"`
	LastSync int64  `json:"lastSync,omitempty"`
}

func (s *Store) pairedDevices() ([]pairedDevice, error) {
	rows, err := s.db.Query(`SELECT p.id,coalesce(nullif(n.v,''),json_extract(CAST(r.body AS TEXT),'$.data.name'),substr(p.id,1,12)),p.role,p.last_ok
		FROM peers p LEFT JOIN settings n ON n.k='peer.name.'||p.id LEFT JOIN replicas r ON r.id=p.id
		ORDER BY p.last_ok DESC,p.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := []pairedDevice{}
	for rows.Next() {
		var d pairedDevice
		if err := rows.Scan(&d.ID, &d.Name, &d.Role, &d.LastSync); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

func (s *Store) addPeer(id, address, role string) error {
	if role != "peer" && role != "viewer" {
		return errors.New("role must be peer or viewer")
	}
	return s.trustPaired(id, address, role, "")
}

func (s *Store) trustPaired(id, address, role, relayURL string, names ...string) error {
	tx, err := s.preparePaired(id, address, role, relayURL, names...)
	if err != nil {
		return err
	}
	return tx.Commit()
}

// The invitation protocol stages the grant only after consent on both screens.
// The caller commits after the other store acknowledges its prepared grant.
func (s *Store) preparePaired(id, address, role, relayURL string, names ...string) (prepared *sql.Tx, err error) {
	if !device.ValidID(id) || id == s.id {
		return nil, errors.New("provide the other device's full public ID")
	}
	switch role {
	case "peer", "source":
		if address == "" && relayURL == "" {
			return nil, errors.New("no route to paired device")
		}
	case "viewer":
	default:
		return nil, errors.New("invalid device role")
	}
	if relayURL != "" {
		var err error
		relayURL, err = relay.NormalizeBase(relayURL)
		if err != nil {
			return nil, err
		}
	}
	if address != "" {
		host, port, err := net.SplitHostPort(address)
		number, portErr := strconv.Atoi(port)
		if err != nil || host == "" || portErr != nil || number < 1 || number > 65535 {
			return nil, errors.New("device address must contain a host and port")
		}
		// The signed invitation may advertise a private direct path. A manual
		// peer add is allowed to supply a user-selected DNS name or public IP.
		if relayURL != "" && !device.PrivateAddress(host) {
			return nil, errors.New("automatic direct address must be a private IP")
		}
	}
	if len(names) > 1 {
		return nil, errors.New("too many device names")
	}
	var name string
	if len(names) == 1 {
		name = strings.TrimSpace(names[0])
		if name != "" && !device.ValidPairName(name) {
			return nil, errors.New("invalid device name")
		}
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer func() {
		if prepared == nil {
			tx.Rollback()
		}
	}()
	saved, err := tx.Exec(`INSERT INTO peers(id,address,role) VALUES(?,?,?)
		ON CONFLICT(id) DO UPDATE SET address=excluded.address, role=excluded.role,last_error=''
		WHERE peers.role=excluded.role OR ?`, id, address, role, relayURL == "")
	if err != nil {
		return nil, err
	}
	if rows, err := saved.RowsAffected(); err != nil {
		return nil, err
	} else if rows == 0 {
		return nil, errors.New("remove the existing pairing before changing its permission")
	}
	if relayURL == "" {
		_, err = tx.Exec("DELETE FROM settings WHERE k=?", "peer.relay."+id)
	} else {
		_, err = tx.Exec("INSERT OR REPLACE INTO settings(k,v) VALUES(?,?)", "peer.relay."+id, relayURL)
	}
	if err != nil {
		return nil, err
	}
	if name != "" {
		if _, err = tx.Exec("INSERT OR REPLACE INTO settings(k,v) VALUES(?,?)", "peer.name."+id, name); err != nil {
			return nil, err
		}
	}
	return tx, nil
}

func (s *Store) removePeer(id string) error {
	if !device.ValidID(id) {
		return errors.New("invalid device ID")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("DELETE FROM peers WHERE id=?", id); err != nil {
		return err
	}
	if _, err = tx.Exec("DELETE FROM settings WHERE k IN (?,?)", "peer.relay."+id, "peer.name."+id); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) peerRoutes(ctx context.Context, id string, includeSources bool) ([]peerRoute, error) {
	query := `SELECT p.id,p.address,coalesce(r.v,'') FROM peers p
		LEFT JOIN settings r ON r.k='peer.relay.'||p.id
		WHERE (p.role='peer' OR (p.role='source' AND ?))`
	args := []any{includeSources}
	if id != "" {
		query += " AND p.id=?"
		args = append(args, id)
	}
	rows, err := s.db.QueryContext(ctx, query+" ORDER BY p.last_ok DESC,p.id", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var routes []peerRoute
	for rows.Next() {
		var p peerRoute
		if err := rows.Scan(&p.ID, &p.Direct, &p.Relay); err != nil {
			return nil, err
		}
		routes = append(routes, p)
	}
	return routes, rows.Err()
}

func (s *Store) checkOutboundGrant(ctx context.Context, id string, includeSources bool) error {
	var allowed bool
	err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM peers WHERE id=? AND (role='peer' OR (role='source' AND ?)))", id, includeSources).Scan(&allowed)
	if err == nil && !allowed {
		return errors.New("outbound device authorization revoked")
	}
	return err
}

func (s *Store) recordPeerAttempt(ctx context.Context, id string, result error) error {
	if result == nil {
		_, err := s.db.ExecContext(ctx, "UPDATE peers SET last_ok=?,last_error='' WHERE id=?", time.Now().Unix(), id)
		return err
	}
	_, err := s.db.ExecContext(ctx, "UPDATE peers SET last_error=? WHERE id=?", result.Error(), id)
	return err
}

func (s *Store) peerClient(p peerRoute, timeout time.Duration) (*http.Client, error) {
	return device.PeerClient(s.key, p, timeout)
}
