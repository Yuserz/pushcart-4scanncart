import axios from 'axios';
import { axiosService } from '@/app/api/axios-client';

// ---------- types ----------
export interface PosStation {
  id: string;
  name: string;
  created_at?: string;
  updated_at?: string | null;
}

export interface PosProduct {
  id: string;
  name: string;
  sku: string;
  price: number;
  stock_quantity: number;
}

export interface PosMappingRow {
  class_slug: string;
  product_id: string;
  note: string | null;
  products: { name: string; sku: string } | null;
}

export interface PosSessionRow {
  id: string;
  station_id: string;
  session_ref: string;
  cart_id: string;
  status: string;
  created_at: string;
  last_activity_at: string;
  stations: { name: string } | null;
  carts: { code_token: string } | null;
}

export interface PosUnmappedClass {
  class_name: string;
  last_seen: string;
}

export interface PosCustomerEdit {
  id: string;
  session_ref: string;
  payload: {
    product_id?: string;
    from_qty?: number;
    to_qty?: number;
  } | null;
  created_at: string;
}

export interface PosOverview {
  sessions: PosSessionRow[];
  products: PosProduct[];
  unmapped: PosUnmappedClass[];
  customer_edits: PosCustomerEdit[];
}

export interface PosSessionInfo {
  session_ref: string;
  cart_id: string;
  cart_code: string;
  // The daily human label ("Shopper_0007") pos_open_session assigned; null for a cart that
  // never opened a session. The UUID stays the machine key — this is display only.
  shopper_code?: string | null;
  last_sync_at: string | null;
  // What the scanner saw and could not resolve (SCANnCART basket mode). Above zero, Finish
  // is refused until staff have checked the basket. Older rows report neither field.
  pending_review?: number;
  review_reasons?: string[];
}

export interface PosCartItem {
  id: string;
  product_id: string;
  quantity: number;
  // When the camera last reported it could no longer account for this row (the desktop's
  // `lost` flag, stamped by pos_reconcile). Non-null renders as the row's pending state:
  // the item is still charged, but the camera no longer sees it. Older rows report nothing.
  camera_lost_at?: string | null;
  products: {
    id: string;
    name: string;
    sku: string;
    price: number;
    stock_quantity: number;
    image_url: string | null;
  };
}

// Carries the route's {error, items} body so callers can name short-stock items.
export class PosApiError extends Error {
  data: { error?: string; items?: unknown } | undefined;

  constructor(message: string, data?: { error?: string; items?: unknown }) {
    super(message);
    this.name = 'PosApiError';
    this.data = data;
  }
}

const apiError = (e: unknown): never => {
  if (axios.isAxiosError(e)) {
    const body = e.response?.data as
      | { error?: string; items?: unknown }
      | undefined;
    throw new PosApiError(body?.error ?? e.message, body);
  }
  throw e;
};

// The active VAT percentage (12.00 means 12%), the same rule pos_finish applies.
export const getActiveVatRate = async (): Promise<number> => {
  try {
    const response = await axiosService.get('/api/protected/vat/all');
    return Number(response.data?.data?.vat?.rate ?? 0);
  } catch (e) {
    return apiError(e);
  }
};

// ---------- tablet ----------
export const getStations = async (): Promise<PosStation[]> => {
  try {
    const response = await axiosService.get('/api/protected/stations');
    return response.data.data as PosStation[];
  } catch (e) {
    return apiError(e);
  }
};

export const openStationSession = async (
  stationId: string,
  cartId: string,
): Promise<{
  session_ref: string;
  cart_id: string;
  cart_code: string;
  shopper_code: string | null;
}> => {
  try {
    const response = await axiosService.post('/api/protected/station-session', {
      station_id: stationId,
      cart_id: cartId,
    });
    return response.data.data;
  } catch (e) {
    return apiError(e);
  }
};

export const getMySession = async (): Promise<PosSessionInfo | null> => {
  try {
    const response = await axiosService.get('/api/protected/station-session');
    return (response.data.data as PosSessionInfo) ?? null;
  } catch (e) {
    return apiError(e);
  }
};

export const getPosCartItems = async (
  cartId: string,
): Promise<PosCartItem[]> => {
  try {
    const response = await axiosService.get(
      `/api/protected/cart_items/${cartId}/active`,
    );
    return (response.data.data as PosCartItem[]) ?? [];
  } catch (e) {
    return apiError(e);
  }
};

// The one manual correction on a camera-managed cart: staff lower a quantity, behind a PIN.
// Customer add/change/remove is gone — the camera owns the cart.
export const staffRemovePosItem = async (
  cartId: string,
  productId: string,
  quantity: number,
  pin: string,
): Promise<void> => {
  try {
    await axiosService.post(
      `/api/protected/station-session/items/${productId}/staff-remove`,
      { cart_id: cartId, quantity, pin },
    );
  } catch (e) {
    return apiError(e);
  }
};

export const finishPosCart = async (
  cartId: string,
): Promise<{ order_id: string }> => {
  try {
    const response = await axiosService.post(
      '/api/protected/station-session/finish',
      { cart_id: cartId },
    );
    return response.data.data;
  } catch (e) {
    return apiError(e);
  }
};

// ---------- admin ----------
export const getPosStations = async (): Promise<PosStation[]> => {
  try {
    const response = await axiosService.get('/api/protected/pos-stations');
    return (response.data.data as PosStation[]) ?? [];
  } catch (e) {
    return apiError(e);
  }
};

export const createPosStation = async (id: string, name: string) => {
  try {
    const response = await axiosService.post('/api/protected/pos-stations', {
      id,
      name,
    });
    return response.data.data as PosStation;
  } catch (e) {
    return apiError(e);
  }
};

export const updatePosStation = async (id: string, name: string) => {
  try {
    await axiosService.put(`/api/protected/pos-stations/${id}`, { name });
  } catch (e) {
    return apiError(e);
  }
};

export const deletePosStation = async (id: string) => {
  try {
    await axiosService.delete(`/api/protected/pos-stations/${id}`);
  } catch (e) {
    return apiError(e);
  }
};

// ---------- staff code (admin) ----------
export interface PosStaffPinStatus {
  /** Where the code in force comes from: set here by an admin, the server's POS_STAFF_PIN, or none. */
  source: 'admin' | 'server' | 'off';
  updated_at: string | null;
  server_fallback: boolean;
}

export const getPosStaffPin = async (): Promise<PosStaffPinStatus> => {
  try {
    const response = await axiosService.get('/api/protected/pos-staff-pin');
    return response.data.data as PosStaffPinStatus;
  } catch (e) {
    return apiError(e);
  }
};

export const setPosStaffPin = async (
  pin: string,
): Promise<PosStaffPinStatus> => {
  try {
    const response = await axiosService.put('/api/protected/pos-staff-pin', {
      pin,
    });
    return response.data.data as PosStaffPinStatus;
  } catch (e) {
    return apiError(e);
  }
};

export const clearPosStaffPin = async (): Promise<PosStaffPinStatus> => {
  try {
    const response = await axiosService.delete('/api/protected/pos-staff-pin');
    return response.data.data as PosStaffPinStatus;
  } catch (e) {
    return apiError(e);
  }
};

export const getPosMapping = async (): Promise<PosMappingRow[]> => {
  try {
    const response = await axiosService.get('/api/protected/pos-mapping');
    return (response.data.data as PosMappingRow[]) ?? [];
  } catch (e) {
    return apiError(e);
  }
};

export const createPosMapping = async (
  classSlug: string,
  productId: string,
  note?: string,
) => {
  try {
    await axiosService.post('/api/protected/pos-mapping', {
      class_slug: classSlug,
      product_id: productId,
      note: note ?? null,
    });
  } catch (e) {
    return apiError(e);
  }
};

export const updatePosMapping = async (
  classSlug: string,
  productId: string,
  note?: string,
) => {
  try {
    await axiosService.put(`/api/protected/pos-mapping/${classSlug}`, {
      product_id: productId,
      note: note ?? null,
    });
  } catch (e) {
    return apiError(e);
  }
};

export const deletePosMapping = async (classSlug: string) => {
  try {
    await axiosService.delete(`/api/protected/pos-mapping/${classSlug}`);
  } catch (e) {
    return apiError(e);
  }
};

export const getPosOverview = async (): Promise<PosOverview> => {
  try {
    const response = await axiosService.get('/api/protected/pos-overview');
    return response.data.data as PosOverview;
  } catch (e) {
    return apiError(e);
  }
};

export const cancelPosSession = async (id: string) => {
  try {
    await axiosService.put(`/api/protected/pos-sessions/${id}`, {
      status: 'cancelled',
    });
  } catch (e) {
    return apiError(e);
  }
};

