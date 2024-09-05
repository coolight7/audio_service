export enum AudioProcessingState {
  idle,
  loading,
  buffering,
  ready,
  completed,
  error,
}

export interface SessionParameter {
  type: string
  params?: string | number
}

