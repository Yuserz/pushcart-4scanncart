'use client';

import { JSX, useCallback, useEffect, useState } from 'react';
import { Container } from '@/components/custom/Container';
import { Card, CardContent, CardHeader } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { Separator } from '@/components/ui/separator';
import { Trash, XCircle, MapPin, CheckCheck } from 'lucide-react';
import {
  cancelPosSession,
  clearPosSessionReview,
  createPosMapping,
  createPosStation,
  deletePosMapping,
  deletePosStation,
  getPosMapping,
  getPosOverview,
  PosApiError,
  type PosCustomerEdit,
  type PosMappingRow,
  type PosOverview,
  type PosProduct,
  type PosSessionRow,
  type PosStation,
  type PosUnmappedClass,
  getPosStations,
} from '@/services/pos/pos.services';
import { StaffCodeCard } from './StaffCodeCard';

function errorText(error: unknown): string {
  if (error instanceof PosApiError) return error.message;
  return String(error);
}

export default function PosMappingPage(): JSX.Element {
  const [stations, setStations] = useState<PosStation[]>([]);
  const [mapping, setMapping] = useState<PosMappingRow[]>([]);
  const [overview, setOverview] = useState<PosOverview | null>(null);
  const [message, setMessage] = useState<string>('');

  const [newStationId, setNewStationId] = useState<string>('');
  const [newStationName, setNewStationName] = useState<string>('');

  const [newClass, setNewClass] = useState<string>('');
  const [newProductId, setNewProductId] = useState<string>('');
  const [newNote, setNewNote] = useState<string>('');

  const refresh = useCallback(async (): Promise<void> => {
    try {
      const [stationList, mappingList, ov] = await Promise.all([
        getPosStations(),
        getPosMapping(),
        getPosOverview(),
      ]);
      setStations(stationList);
      setMapping(mappingList);
      setOverview(ov);
      setMessage('');
    } catch (error) {
      setMessage(errorText(error));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const onAddStation = (): void => {
    void (async () => {
      try {
        await createPosStation(newStationId.trim(), newStationName.trim());
        setNewStationId('');
        setNewStationName('');
        await refresh();
      } catch (error) {
        setMessage(errorText(error));
      }
    })();
  };

  const onDeleteStation = (id: string): void => {
    void (async () => {
      try {
        await deletePosStation(id);
        await refresh();
      } catch (error) {
        setMessage(errorText(error));
      }
    })();
  };

  const onAddMapping = (): void => {
    void (async () => {
      try {
        await createPosMapping(
          newClass.trim(),
          newProductId,
          newNote.trim() || undefined,
        );
        setNewClass('');
        setNewProductId('');
        setNewNote('');
        await refresh();
      } catch (error) {
        setMessage(errorText(error));
      }
    })();
  };

  const onDeleteMapping = (classSlug: string): void => {
    void (async () => {
      try {
        await deletePosMapping(classSlug);
        await refresh();
      } catch (error) {
        setMessage(errorText(error));
      }
    })();
  };

  const onCancelSession = (id: string): void => {
    void (async () => {
      try {
        await cancelPosSession(id);
        await refresh();
      } catch (error) {
        setMessage(errorText(error));
      }
    })();
  };

  // Staff checked the basket by eye (the desktop POS panel's "Basket checked", reachable
  // from here so nobody walks to the desktop): clears the review the tablet blocks on.
  const onClearReview = (id: string): void => {
    void (async () => {
      try {
        await clearPosSessionReview(id);
        await refresh();
      } catch (error) {
        setMessage(errorText(error));
      }
    })();
  };

  const prefill = (item: PosUnmappedClass): void => {
    setNewClass(item.class_name);
  };

  const products: PosProduct[] = overview?.products ?? [];
  const sessions: PosSessionRow[] = overview?.sessions ?? [];
  const unmapped: PosUnmappedClass[] = overview?.unmapped ?? [];
  const edits: PosCustomerEdit[] = overview?.customer_edits ?? [];

  return (
    <Container
      title="POS Mapping"
      description="Pair camera class slugs and counters with this store"
    >
      {message && (
        <p className="mb-4 rounded-md bg-red-500/10 p-3 text-sm text-red-600">
          {message}
        </p>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        {/* Stations */}
        <Card className="shadow-xs">
          <CardHeader>
            <h2 className="text-xl font-bold">Counters (stations)</h2>
            <p className="text-sm text-gray-500">
              Paste a station id into the SCANnCART Admin Panel.
            </p>
          </CardHeader>
          <CardContent className="space-y-3">
            {stations.map((station) => (
              <div
                key={station.id}
                className="flex items-center justify-between gap-2"
              >
                <div>
                  <span className="font-medium">{station.name}</span>
                  <Badge variant="secondary" className="ml-2">
                    {station.id}
                  </Badge>
                </div>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => onDeleteStation(station.id)}
                >
                  <Trash />
                </Button>
              </div>
            ))}
            {stations.length === 0 && (
              <p className="text-sm text-gray-500">No counters yet.</p>
            )}

            <Separator />

            <div className="flex flex-col gap-2 sm:flex-row">
              <Input
                placeholder="id (e.g. counter-1)"
                value={newStationId}
                onChange={(e) => setNewStationId(e.target.value)}
              />
              <Input
                placeholder="name"
                value={newStationName}
                onChange={(e) => setNewStationName(e.target.value)}
              />
              <Button
                onClick={onAddStation}
                disabled={!newStationId.trim() || !newStationName.trim()}
              >
                <MapPin />
                Add
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Class mappings */}
        <Card className="shadow-xs">
          <CardHeader>
            <h2 className="text-xl font-bold">Class mappings</h2>
            <p className="text-sm text-gray-500">
              Several slugs may map to one product.
            </p>
          </CardHeader>
          <CardContent className="space-y-3">
            {mapping.map((row) => (
              <div
                key={row.class_slug}
                className="flex items-center justify-between gap-2"
              >
                <div className="min-w-0">
                  <span className="font-mono text-sm">{row.class_slug}</span>
                  <span className="ml-2 text-sm text-gray-500">
                    → {row.products?.name ?? row.product_id}
                  </span>
                </div>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => onDeleteMapping(row.class_slug)}
                >
                  <Trash />
                </Button>
              </div>
            ))}
            {mapping.length === 0 && (
              <p className="text-sm text-gray-500">Nothing mapped yet.</p>
            )}

            <Separator />

            <div className="flex flex-col gap-2">
              <Input
                placeholder="class slug"
                value={newClass}
                onChange={(e) => setNewClass(e.target.value)}
              />
              <select
                className="border-input h-9 rounded-md border bg-transparent px-3 text-sm"
                value={newProductId}
                onChange={(e) => setNewProductId(e.target.value)}
              >
                <option value="">Select a product…</option>
                {products.map((product) => (
                  <option key={product.id} value={product.id}>
                    {product.name} ({product.sku})
                  </option>
                ))}
              </select>
              <Input
                placeholder="note (optional)"
                value={newNote}
                onChange={(e) => setNewNote(e.target.value)}
              />
              <Button
                onClick={onAddMapping}
                disabled={!newClass.trim() || !newProductId}
              >
                Add mapping
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Unmapped classes */}
        <Card className="shadow-xs">
          <CardHeader>
            <h2 className="text-xl font-bold">Recent unmapped classes</h2>
            <p className="text-sm text-gray-500">
              Seen by the camera but not mapped. Click to prefill the form.
            </p>
          </CardHeader>
          <CardContent className="space-y-2">
            {unmapped.map((item) => (
              <button
                key={item.class_name}
                type="button"
                onClick={() => prefill(item)}
                className="hover:bg-accent flex w-full items-center justify-between rounded-md border p-2 text-left text-sm"
              >
                <span className="font-mono">{item.class_name}</span>
                <span className="text-gray-400">
                  {new Date(item.last_seen).toLocaleString()}
                </span>
              </button>
            ))}
            {unmapped.length === 0 && (
              <p className="text-sm text-gray-500">No unmapped classes.</p>
            )}
          </CardContent>
        </Card>

        {/* Open sessions */}
        <Card className="shadow-xs">
          <CardHeader>
            <h2 className="text-xl font-bold">Open sessions</h2>
            <p className="text-sm text-gray-500">
              Cancel a session stuck by an abandoned tablet.
            </p>
          </CardHeader>
          <CardContent className="space-y-2">
            {sessions.map((session) => (
              <div
                key={session.id}
                className="flex items-center justify-between gap-2 text-sm"
              >
                <div>
                  <span className="font-medium">
                    {session.stations?.name ?? session.station_id}
                  </span>
                  <span className="ml-2 font-mono text-gray-500">
                    {session.session_ref}
                  </span>
                  <div className="text-gray-400">
                    last activity{' '}
                    {new Date(session.last_activity_at).toLocaleString()}
                  </div>
                  {session.pending_review > 0 && (
                    <div
                      className="text-amber-600"
                      title={session.review_reasons.join('\n')}
                    >
                      {session.pending_review} need
                      {session.pending_review === 1 ? '' : 's'} review — latest:{' '}
                      {session.review_reasons.at(-1) ?? 'unknown'}
                    </div>
                  )}
                </div>
                <div className="flex items-center gap-1">
                  {session.pending_review > 0 && (
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => onClearReview(session.id)}
                    >
                      <CheckCheck />
                      Basket checked
                    </Button>
                  )}
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() => onCancelSession(session.id)}
                  >
                    <XCircle />
                    Cancel
                  </Button>
                </div>
              </div>
            ))}
            {sessions.length === 0 && (
              <p className="text-sm text-gray-500">No open sessions.</p>
            )}
          </CardContent>
        </Card>
      </div>

      <StaffCodeCard className="mt-4" />

      {/* Customer edits */}
      <Card className="mt-4 shadow-xs">
        <CardHeader>
          <h2 className="text-xl font-bold">Customer edits</h2>
          <p className="text-sm text-gray-500">
            The shrinkage trail: tablet edits and removals.
          </p>
        </CardHeader>
        <CardContent className="space-y-2">
          {edits.map((edit) => (
            <div
              key={edit.id}
              className="flex items-center justify-between gap-2 text-sm"
            >
              <span className="font-mono text-gray-500">
                {edit.payload?.product_id ?? '—'}
              </span>
              <span>
                {edit.payload?.from_qty ?? '—'} → {edit.payload?.to_qty ?? '—'}
              </span>
              <span className="text-gray-400">
                {new Date(edit.created_at).toLocaleString()}
              </span>
            </div>
          ))}
          {edits.length === 0 && (
            <p className="text-sm text-gray-500">No customer edits yet.</p>
          )}
        </CardContent>
      </Card>
    </Container>
  );
}
