import axios from 'axios';
import { axiosService } from '@/app/api/axios-client';
import { toast } from 'sonner';
import { Carts } from '@/lib/types/Carts';

export const updateCartStatus = async (
  status: string,
  id: string,
): Promise<void> => {
  try {
    const response = await axiosService.put(`/api/protected/cart/${id}`, {
      status,
      type: 'update-cart-status',
    });

    toast('Successfully', {
      description: response.data.message,
    });

    return response.data.data;
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};

export const getCarts = async (
  params: string,
): Promise<Carts[] | undefined> => {
  try {
    const response = await axiosService.get(`/api/protected/cart${params}`);

    return response.data.data as Carts[];
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};

export const getCartsById = async (id: string) => {
  try {
    const response = await axiosService.get(
      `/api/protected/cart/get_one/${id}`,
    );

    return response.data.data as Carts;
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};

export const getCartItemsById = async (
  cartId: string,
  status: string,
): Promise<void> => {
  try {
    const response = await axiosService.get(
      `/api/protected/cart_items/${cartId}/${status}`,
    );

    return response.data.data;
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};

export const updateCartItemsQuantity = async (
  quantity: number,
  id: string,
): Promise<void> => {
  try {
    const response = await axiosService.put(`/api/protected/cart_items/${id}`, {
      quantity,
      type: 'update-quantity',
    });

    toast('Successfully', {
      description: response.data.message,
    });

    return response.data.data;
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};

export const addToCart = async (
  cartId: string,
  productId: string,
): Promise<void> => {
  try {
    const response = await axiosService.post('/api/protected/cart_items', {
      cartId,
      productId,
      type: 'add-to-cart',
    });

    toast('Successfully', {
      description: response.data.message,
    });

    return response.data.data;
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};

export const deleteCartItems = async (id: string) => {
  try {
    const response = await axiosService.delete(
      `/api/protected/cart_items/${id}`,
    );

    toast('Successfully', {
      description: response.data.message,
    });

    return response.data.data;
  } catch (e) {
    if (axios.isAxiosError(e)) {
      toast.error('ERROR!', {
        description: e.response?.data.error,
      });
      throw e.response?.data.error;
    }
  }
};
