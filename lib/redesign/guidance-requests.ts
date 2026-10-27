/** A confirmed write invalidates every earlier periodic read. Context changes
 * invalidate writes too, so an old account/role cannot update the new screen. */
export class GuidanceRequests {
  private epoch=0;
  private read=0;
  private writing=false;
  invalidate(){this.epoch++;this.read++;this.writing=false;}
  beginRead(){return this.writing?null:{epoch:this.epoch,read:++this.read};}
  acceptsRead(token:{epoch:number;read:number}){return !this.writing&&token.epoch===this.epoch&&token.read===this.read;}
  beginWrite(){if(this.writing)return null;this.writing=true;return ++this.epoch;}
  acceptsWrite(token:number){return this.writing&&token===this.epoch;}
  endWrite(token:number){if(!this.acceptsWrite(token))return;this.writing=false;this.epoch++;}
}
