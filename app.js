export default {
  onLaunch() {
    console.log('[照片删除] App Launch');
  },
  onShow() {
    console.log('[照片删除] App Show');
  },
  onHide() {
    console.log('[照片删除] App Hide');
  },
  onError(err) {
    console.error('[照片删除] App Error', err);
  },
  globalData: {
    ready: false,
  },
};
